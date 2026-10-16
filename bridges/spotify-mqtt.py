#!/usr/bin/env python3
"""Spotify (any MPRIS player) <-> MQTT bridge, for deckd or anything else.

Run one on each Linux PC. Needs only python3 and systemd's busctl — no
playerctl, no paho: it speaks MPRIS over D-Bus and has a tiny MQTT client
built in (QoS 0, no TLS, LAN broker, literal IP or hostname).

Environment:
    SPOTIFY_MQTT_HOST      broker (required)
    SPOTIFY_MQTT_PORT      1883
    SPOTIFY_MQTT_USER / SPOTIFY_MQTT_PASS
    SPOTIFY_MQTT_TOPIC     topic prefix, "spotify"
    SPOTIFY_MQTT_NAME      this machine's name in topics, default the hostname
    SPOTIFY_PLAYERS        comma list of MPRIS player names, "spotify,spotifyd"

Per-machine topics (<p> = prefix, <h> = name) — always act, whoever is playing:
    <p>/<h>/cmd        play | pause | play-pause | stop | next | previous
    <p>/<h>/vol/set    0-100
    <p>/<h>/vol/adj    signed step, e.g. -5 / 5
    <p>/<h>/skip       >0 next, <0 previous
    <p>/<h>/status     online / offline (retained; offline is the last-will)
    <p>/<h>/state/{playing,artist,track,album,volume}   (retained)

Shared topics — the same commands without <h>, e.g. <p>/cmd. Only the
"active" machine acts on them: the one that is playing, or, when nothing is,
the one that played last. That machine also mirrors its state to
<p>/state/{playing,artist,track,album,volume} and names itself in
<p>/state/host, so a controller needs just one set of topics and follows
whichever PC has music on.
"""
import json
import os
import re
import select
import socket
import struct
import subprocess
import sys
import time

DEST_PREFIX = "org.mpris.MediaPlayer2."
PATH = "/org/mpris/MediaPlayer2"
IFACE = "org.mpris.MediaPlayer2.Player"
FIELDS = ("playing", "artist", "track", "album", "volume")


def env(name, default=""):
    return os.environ.get(name) or default


# ---- minimal MQTT 3.1.1 client ---------------------------------------------

def _str(s):
    b = s.encode()
    return struct.pack(">H", len(b)) + b


def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


class Mqtt:
    def __init__(self, host, port, user, password, client_id, will_topic):
        self.host, self.port = host, port
        self.user, self.password = user, password
        self.client_id, self.will_topic = client_id, will_topic
        self.sock = None
        self.subs = []

    def connect(self):
        s = socket.create_connection((self.host, self.port), timeout=5)
        flags = 0x02 | 0x04 | 0x20  # clean session, will, will retain
        body = _str("MQTT") + bytes([4]) + b"\0" + struct.pack(">H", 60) + _str(self.client_id)
        body += _str(self.will_topic) + _str("offline")
        if self.user:
            flags |= 0x80
            body += _str(self.user)
        if self.password:
            flags |= 0x40
            body += _str(self.password)
        body = body[:7] + bytes([flags]) + body[8:]
        s.sendall(b"\x10" + _varint(len(body)) + body)
        ack = self._recv_exact(s, 4)
        if ack[0] != 0x20 or ack[3] != 0:
            raise ConnectionError(f"broker refused connection (rc={ack[3]})")
        s.settimeout(None)
        self.sock = s
        for i, topic in enumerate(self.subs, 1):
            self._send(b"\x82" + _varint(2 + 2 + len(topic.encode()) + 1) + struct.pack(">H", i) + _str(topic) + b"\0")

    @staticmethod
    def _recv_exact(s, n):
        buf = b""
        while len(buf) < n:
            chunk = s.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("broker closed the connection")
            buf += chunk
        return buf

    def _send(self, data):
        self.sock.sendall(data)

    def publish(self, topic, payload, retain=False):
        p = payload.encode() if isinstance(payload, str) else payload
        self._send(bytes([0x31 if retain else 0x30]) + _varint(2 + len(topic.encode()) + len(p)) + _str(topic) + p)

    def ping(self):
        self._send(b"\xc0\x00")

    def read(self, timeout):
        """Wait up to `timeout` for one packet. Returns (topic, payload, retain) or None."""
        if not select.select([self.sock], [], [], timeout)[0]:
            return None
        b0 = self._recv_exact(self.sock, 1)[0]
        n, shift = 0, 0
        while True:
            b = self._recv_exact(self.sock, 1)[0]
            n |= (b & 0x7F) << shift
            if not b & 0x80:
                break
            shift += 7
        body = self._recv_exact(self.sock, n) if n else b""
        if b0 >> 4 != 3:
            return None  # SUBACK, PINGRESP, ...
        tlen = struct.unpack(">H", body[:2])[0]
        topic = body[2:2 + tlen].decode("utf-8", "replace")
        off = 2 + tlen + (2 if (b0 >> 1) & 3 else 0)
        return topic, body[off:].decode("utf-8", "replace"), bool(b0 & 1)

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass
        self.sock = None


# ---- MPRIS via busctl ------------------------------------------------------

def busctl(*args):
    return subprocess.run(["busctl", "--user", "--json=short", *args], capture_output=True, text=True, timeout=3)


def find_player(wanted):
    r = subprocess.run(["busctl", "--user", "--no-legend", "list"], capture_output=True, text=True, timeout=3)
    for line in r.stdout.splitlines():
        name = line.split()[0] if line.split() else ""
        if name.startswith(DEST_PREFIX):
            short = name[len(DEST_PREFIX):]
            if any(short == w or short.startswith(w + ".") for w in wanted):
                return name
    return None


def read_state(dest):
    """Returns a dict of FIELDS, or None if the player vanished."""
    r = busctl("call", dest, PATH, "org.freedesktop.DBus.Properties", "GetAll", "s", IFACE)
    if r.returncode != 0:
        return None
    props = json.loads(r.stdout)["data"][0]
    meta = props.get("Metadata", {}).get("data", {})

    def m(key):
        return meta.get(key, {}).get("data", "")

    artist = m("xesam:artist")
    return {
        "playing": "on" if props.get("PlaybackStatus", {}).get("data") == "Playing" else "off",
        "artist": ", ".join(artist) if isinstance(artist, list) else str(artist),
        "track": str(m("xesam:title")),
        "album": str(m("xesam:album")),
        "volume": str(int(round(float(props.get("Volume", {}).get("data", 0)) * 100))),
    }


def call(dest, method):
    busctl("call", dest, PATH, IFACE, method)


def set_volume(dest, percent):
    percent = max(0, min(100, percent))
    busctl("set-property", dest, PATH, IFACE, "Volume", "d", str(percent / 100))


def run_command(dest, state, kind, payload):
    payload = payload.strip()
    if kind == "cmd":
        method = {"play": "Play", "pause": "Pause", "play-pause": "PlayPause", "stop": "Stop",
                  "next": "Next", "previous": "Previous"}.get(payload)
        if method:
            call(dest, method)
    elif kind == "skip":
        n = int(payload)
        if n:
            call(dest, "Next" if n > 0 else "Previous")
    elif kind in ("vol/set", "vol/adj"):
        n = int(payload)
        cur = int((state or {}).get("volume") or 0)
        set_volume(dest, n if kind == "vol/set" else cur + n)


# ---- bridge ----------------------------------------------------------------

def main():
    host = env("SPOTIFY_MQTT_HOST")
    if not host:
        sys.exit("SPOTIFY_MQTT_HOST is not set")
    port = int(env("SPOTIFY_MQTT_PORT", "1883"))
    prefix = env("SPOTIFY_MQTT_TOPIC", "spotify").strip("/")
    me = re.sub(r"[/#+\s]", "-", env("SPOTIFY_MQTT_NAME") or socket.gethostname())
    wanted = [w.strip() for w in env("SPOTIFY_PLAYERS", "spotify,spotifyd").split(",") if w.strip()]
    mine, shared = f"{prefix}/{me}", prefix

    kinds = ("cmd", "skip", "vol/set", "vol/adj")
    mq = Mqtt(host, port, env("SPOTIFY_MQTT_USER"), env("SPOTIFY_MQTT_PASS"), f"spotify-{me}", f"{mine}/status")
    mq.subs = [f"{base}/{k}" for base in (mine, shared) for k in kinds] + [f"{shared}/state/host"]

    active_host = None
    state = None
    last = {}

    def pub(topic, value):
        if last.get(topic) != value:
            mq.publish(topic, value, retain=True)
            last[topic] = value

    def sync():
        nonlocal state, active_host
        dest = find_player(wanted)
        new = read_state(dest) if dest else None
        state = new
        values = new or {"playing": "off", "artist": "", "track": "", "album": "", "volume": "0"}
        for f in FIELDS:
            if new or f == "playing":  # a closed player only flips playing to off
                pub(f"{mine}/state/{f}", values[f])
        playing = values["playing"] == "on"
        if playing and active_host != me:
            mq.publish(f"{shared}/state/host", me, retain=True)
            active_host = me
            for f in FIELDS:
                last.pop(f"{shared}/state/{f}", None)
        if playing or active_host == me:
            for f in FIELDS:
                if new or f == "playing":
                    pub(f"{shared}/state/{f}", values[f])
        return dest

    def handle(topic, payload, retain):
        nonlocal active_host
        if topic == f"{shared}/state/host":
            active_host = payload or None
            return
        if retain:
            return  # never replay a stale command
        for base, always in ((mine, True), (shared, False)):
            for k in kinds:
                if topic == f"{base}/{k}":
                    playing = bool(state) and state["playing"] == "on"
                    if not always and not (playing or active_host == me):
                        return
                    dest = find_player(wanted)
                    if dest:
                        try:
                            run_command(dest, state, k, payload)
                        except (ValueError, subprocess.SubprocessError) as e:
                            print(f"spotify-mqtt: bad {k} {payload!r}: {e}", file=sys.stderr)
                    return

    while True:
        try:
            mq.connect()
            print(f"spotify-mqtt: connected to {host}:{port} as {me}", flush=True)
            mq.publish(f"{mine}/status", "online", retain=True)
            last.clear()
            next_tick, next_ping = 0.0, time.time() + 20
            while True:
                now = time.time()
                if now >= next_tick:
                    sync()
                    next_tick = now + 1.0
                if now >= next_ping:
                    mq.ping()
                    next_ping = now + 20
                pkt = mq.read(max(0.05, min(next_tick, next_ping) - time.time()))
                if pkt:
                    handle(*pkt)
                    sync()  # show the effect of a command promptly
                    next_tick = time.time() + 1.0
        except (OSError, ConnectionError) as e:
            print(f"spotify-mqtt: {e}; retrying in 2s", file=sys.stderr, flush=True)
            if mq.sock:
                mq.close()
            time.sleep(2)


if __name__ == "__main__":
    main()
