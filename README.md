# deckd-zig

A Linux daemon for the **Elgato Stream Deck Plus**, written from scratch in
Zig over raw hidraw — no libraries, no official SDK. It turns the deck into a
controller for two local projects:

- **[matrix_sim](../matrix_sim)** — the 64×32 HUB75 LED panel (via its HTTP
  control API), and
- **[soma-zig](../soma-zig)** — the SomaFM terminal player (via its Unix-socket
  IPC).

Plus a publish-only **MQTT** page: each key sends its configured
topic/payload to a LAN broker, for lights or anything else that listens.

Everything on the device works: the 8 LCD keys (120×120 JPEG each), the
800×100 touch strip, and the 4 rotary encoder knobs (turn + push).

## Building

Pinned to zig 0.16.0 (see `.tool-versions`; matches soma-zig):

```
cd zig
zig build          # produces zig-out/bin/deckd (+ deckd-config if gtk4 is found)
zig build test     # protocol parser tests (built from real captured bytes)
```

Vendored: `stb_image_write.h` for JPEG encoding (keys/strip only accept JPEG),
`stb_image.h` for decoding icon files (see `icon` in Configuration below).

## Running

```
deckd run                          # uses ~/.config/deckd/config.json
deckd run http://192.168.1.109:8787   # CLI URL beats the config file
```

The device is auto-discovered by scanning `/sys/class/hidraw/*/device/uevent`
for VID `0fd9` / PID `0084`; `--device /dev/hidrawN` overrides. Your user needs
rw on the hidraw node (logind's `uaccess` tag usually covers the active
session; otherwise a udev rule).

The daemon polls the matrix and soma every 2 s and redraws only when what the
deck shows actually changes (signature-driven), so it's quiet when idle. The
matrix being unreachable shows `MATRIX OFFLINE` on the strip instead of
killing the daemon; same for `SOMA OFFLINE`.

## Configuration

`~/.config/deckd/config.json` — everything is optional and falls back to the
defaults in `zig/src/config.zig`:

```json
{
  "matrix_url": "http://192.168.1.109:8787",
  "brightness": 80,
  "font_path": "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Bold.ttf",
  "font_size_key": 22,
  "font_size_strip": 30,
  "matrix_keys": [ { "label": "WEATHER", "screen": "weather-cyberpunk", "color": "ff8c00" } ],
  "soma_keys":   [ { "label": "GROOVE",  "id": "groovesalad",        "color": "78dc78" } ],
  "mqtt_host": "192.168.1.10",
  "mqtt_port": 1883,
  "mqtt_user": "",
  "mqtt_pass": "",
  "mqtt_keys": [ { "label": "LT ON", "topic": "home/lights/set", "payload": "ON", "color": "ffc850" } ]
}
```

Key lists patch the default 8-key maps **by index**; an entry may set just the
fields it changes. Soma keys take any SomaFM channel id plus the special ids
`viz` and `stop`. MQTT keys publish `payload` to `topic` when pressed — an
empty `topic` makes the key inert. `mqtt_host` must be a literal IP (or
`localhost`); no DNS, no TLS — LAN brokers only. `mqtt_user`/`mqtt_pass` are
optional. Knob roles are not configurable yet.

Each key entry also takes an `"icon"` (absolute path, no `~` expansion — same
convention as `font_path`): when set, it's drawn on the key (scaled to fit,
alpha-blended, centered) instead of the label.

- **Format**: PNG, JPEG, BMP, or GIF. Use PNG for a transparent background —
  alpha is honored, so it blends into the key's configured `color` instead of
  showing a black box.
- **Size**: no fixed requirement (it's scaled to fit, letterboxed, aspect
  preserved), but the keys are **80×80** on the Mini and **120×120** on the
  Plus, and scaling is nearest-neighbor — downscaling a bigger image looks
  clean, upscaling a small one looks blocky. **120×120 square** is a safe
  default that downscales fine to the Mini too.
- The source file is read into a fixed 1 MiB buffer — plenty for an icon,
  but a larger file is rejected outright rather than truncated.

### Config GUI

`zig-out/bin/deckd-config` — a standalone GTK4 app for editing
`config.json` without hand-writing JSON: every field above, all 8 possible
key slots per array (a Mini/Plus toggle just dims the ones a 6-key Mini
ignores — it never discards them), a color picker, and a file picker for
`icon`. Entirely independent of the daemon; it shares nothing but the
on-disk schema. Only built when `pkg-config --exists gtk4` succeeds —
skipped (with a note, not a failure) on a headless build with no GTK. Saving
keeps one rotating `.bak` of whatever it overwrites.

### Fonts

`font_path` can point at **any .ttf** — text is rasterized with stb_truetype.
Nerd Fonts (https://www.nerdfonts.com/font-downloads) work including their
Private-Use-Area icon glyphs, so labels can be icons, e.g.
`"label": "\uf001"` (labels are UTF-8 JSON strings). Sizes are em-px for the
120×120 keys and the strip's main line; sub-lines render at 16 px. Omit
`font_path` (or point it at a missing file) to fall back to the built-in 8×8
bitmap font. See what's installed with `fc-list | grep -i nerd`.

## Testing under pm2

```
cd zig && zig build && cd ..
pm2 start ecosystem.config.js       # or: pm2 restart deckd
pm2 logs deckd
```

Rebuild-then-restart is the iteration loop (watch mode is off on purpose:
`zig build` replaces the binary wholesale). pm2 stops being involved at
production time — see below.

## Run at login (production)

```
cp systemd/deckd.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now deckd
journalctl --user -u deckd -f     # watch it
```

Runs unprivileged (the hidraw ACL comes from logind). To also start it at
boot before login: `sudo loginctl enable-linger $USER`.

**Never run pm2 and the systemd service at the same time** — two deckd
processes share the hidraw node and fight over the deck
(`pm2 stop deckd` before `systemctl --user start deckd`, and vice versa).

## Deploying to other servers

`packaging/` has a PKGBUILD (Arch) and a SlackBuild (Slackware), both
building straight from a git checkout — see `packaging/README.md`.

## Controls

**Knob 4 push cycles pages: MATRIX → SOMA → MIRROR → MQTT.** Knob roles are fixed
on all pages:

| Knob | Rotate | Push |
|---|---|---|
| 1 (leftmost) | soma volume ±5% | mute toggle |
| 2 | soma channel surf | play/stop toggle |
| 3 | matrix screen jog | **auto-advance toggle** |
| 4 | deck LCD brightness ±5% | **switch page** |

Swiping left/right on the touch strip also jogs matrix screens.

### MATRIX page

Keys jump straight to a screen (`POST /screen/<name>`); the active screen's
key gets a white border:

| WEATHER | HIGH | CLOCK | AQI | HUMID | SPECTR | SCOPE | MSG |
|---|---|---|---|---|---|---|---|
| weather-cyberpunk | high-temp-cyberpunk | clock-cyberpunk | aqi-cyberpunk | humidity-cyberpunk | spectrum | oscope | message |

Strip: current screen name, `AUTO ON/OFF`, and the soma now-playing line when
music is playing.

### SOMA page

Keys are SomaFM channel presets (border = the one playing), plus VIZ (cycles
the visualizer pattern) and STOP:

| GROOVE | DRONE | DEFCON | AGENT | LUSH | DEEP | VIZ | STOP |
|---|---|---|---|---|---|---|---|
| groovesalad | dronezone | defcon | secretagent | lush | deepspaceone | — | — |

Strip: channel name (or `SOMA (stopped)`), current track, `VOL n%`.

### MIRROR page

The strip shows the **live matrix framebuffer** (64×32, integer-scaled and
centered), streamed from matrix_server's WebSocket broadcast on port 8888 —
the same feed `led-matrix-simulator.html` uses. Redraws are throttled to ~4
fps. Keys behave like the MATRIX page, so you can switch screens while
watching the mirror.

### MQTT page

Keys publish their configured topic/payload to the broker (QoS 0, one
connection per press) — lights, switches, scripts, anything that subscribes.
No per-key state readback (publish-only), so no active border. Strip: broker
host and the last published `topic = payload`; `MQTT OFFLINE` if the last
publish failed, `MQTT NOT CONFIGURED` until `mqtt_host` is set.

## Dev CLI

```
deckd info            # firmware + serial (feature reports 0x05/0x06)
deckd dump            # hex-dump + parse input reports (press keys, turn knobs)
deckd brightness 70   # panel backlight
deckd reset           # device reset (feature report 0x03)
deckd test-image      # orientation pattern on all keys + strip
deckd pub home/lights/set ON   # one-off MQTT publish (broker from config; no deck needed)
```

## Wire protocol (verified on hardware)

Feature reports are 32 bytes (`HIDIOCGFEATURE`/`HIDIOCSFEATURE` ioctls);
image transfers are 1024-byte output reports; input reports are 256 bytes.

**Input** (`deckd dump`): byte 0 = report id `0x01`, byte 1 = class,
byte 2 = payload length:

| class | layout |
|---|---|
| `0x00` keys | `[4..12]` u8 state per key (1 = pressed); full snapshot each change |
| `0x03` dials | `[4]=0x00` → `[5..9]` u8 press state per dial; `[4]=0x01` → `[5..9]` i8 turn deltas (CW positive) |
| `0x02` touch | `[4]=0x01` tap / `0x02` long press: x,y u16le at `[6]`,`[8]`; `[4]=0x03` swipe: x0,y0,x1,y1 at 6,8,10,12 |

**Key image**: report `0x02`, command `0x07`, 8-byte header
`[id, cmd, key, last, len_lo, len_hi, page_lo, page_hi]`, payload paged at
1016 bytes/report. 120×120 JPEG, no rotation/flip needed.

**Strip image**: report `0x02`, command `0x0c`, 16-byte header
`[id, cmd, x, y, w, h (u16le each), last, page_lo, page_hi, len_lo, len_hi, 0]`
— note **page before length** (swapped vs. keys; getting this wrong garbles
the image into noise lines). 800×100 JPEG, no rotation needed.

## Interfaces it depends on

- **matrix_sim control server** (`:8787`): `GET /screen`, `GET/POST /config`,
  `POST /screen/<name>` (direct select, added for this project),
  `POST /next-screen`.
- **soma-zig IPC** (`$XDG_RUNTIME_DIR/soma.sock`, line-based):
  `status` → one-line JSON `{"playing","connecting","channel","channel_id","track","volume"}`;
  commands `vol N | vol ±N`, `mute`, `play [id]`, `stop`, `toggle`,
  `next`/`prev` (selection), `surf-next`/`surf-prev` (selection + play),
  `viz next`. Replies are one line (`ok` / `err ...`).
- **MQTT broker** (outbound TCP, default port 1883): MQTT 3.1.1, publish-only,
  QoS 0, optional username/password — implemented from scratch in `mqtt.zig`.

## Files

| File | Purpose |
|---|---|
| `zig/src/hid.zig` | hidraw open/discovery, feature reports, report I/O |
| `zig/src/deck.zig` | wire protocol: image upload, input parsing (+ tests) |
| `zig/src/image.zig` | RGB framebuffer → JPEG (stb_image_write) |
| `zig/src/render.zig` | text/shape drawing (`font8x8.zig`, public-domain 8×8 font) |
| `zig/src/matrix.zig` | matrix_sim HTTP control client |
| `zig/src/soma.zig` | soma-zig IPC client |
| `zig/src/mqtt.zig` | publish-only MQTT 3.1.1 client (QoS 0, no TLS) |
| `zig/src/ws.zig` | WebSocket client for the matrix framebuffer stream |
| `zig/src/config.zig` | `~/.config/deckd/config.json` loading + default key maps |
| `zig/src/daemon.zig` | pages, knob wiring, strip layouts, main loop |
| `zig/src/main.zig` | CLI (`run` + dev commands) |
| `zig/src/config_gui.zig` | `deckd-config`: standalone GTK4 config.json editor |
| `zig/tools/gen_gtk_header.sh` | flattens the system's gtk/gtk.h for `deckd-config`'s `@cImport` |
| `systemd/deckd.service` | user service for running at login |
| `packaging/` | PKGBUILD (Arch) and SlackBuild (Slackware) for deploying to other servers |

## Backlog

- Configurable knob roles (currently hardcoded)
- Per-band auto-gain in soma-zig's visualizer (high bands read low)
