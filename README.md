# deckd-zig

A Linux daemon for the **Elgato Stream Deck Plus**, written from scratch in
Zig over raw hidraw — no libraries, no official SDK. It turns the deck into a
controller for two local projects:

- **[matrix_sim](../matrix_sim)** — the 64×32 HUB75 LED panel (via its HTTP
  control API), and
- **[soma-zig](../soma-zig)** — the SomaFM terminal player (via its Unix-socket
  IPC).

Everything on the device works: the 8 LCD keys (120×120 JPEG each), the
800×100 touch strip, and the 4 rotary encoder knobs (turn + push).

## Building

Pinned to zig 0.16.0 (see `.tool-versions`; matches soma-zig):

```
cd zig
zig build          # produces zig-out/bin/deckd
zig build test     # protocol parser tests (built from real captured bytes)
```

Vendored: `stb_image_write.h` for JPEG encoding (keys/strip only accept JPEG).

## Running

```
deckd run                          # matrix at http://localhost:8787
deckd run http://192.168.1.160:8787   # the real panel on the Pi
```

The device is auto-discovered by scanning `/sys/class/hidraw/*/device/uevent`
for VID `0fd9` / PID `0084`; `--device /dev/hidrawN` overrides. Your user needs
rw on the hidraw node (logind's `uaccess` tag usually covers the active
session; otherwise a udev rule).

The daemon polls the matrix and soma every 2 s and redraws only when what the
deck shows actually changes (signature-driven), so it's quiet when idle. The
matrix being unreachable shows `MATRIX OFFLINE` on the strip instead of
killing the daemon; same for `SOMA OFFLINE`.

## Controls

**Knob 4 push switches pages.** Knob roles are fixed on all pages:

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

Key maps are hardcoded in `zig/src/daemon.zig` (`matrix_keys`, `soma_keys`) —
a config file is on the backlog.

## Dev CLI

```
deckd info            # firmware + serial (feature reports 0x05/0x06)
deckd dump            # hex-dump + parse input reports (press keys, turn knobs)
deckd brightness 70   # panel backlight
deckd reset           # device reset (feature report 0x03)
deckd test-image      # orientation pattern on all keys + strip
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

## Files

| File | Purpose |
|---|---|
| `zig/src/hid.zig` | hidraw open/discovery, feature reports, report I/O |
| `zig/src/deck.zig` | wire protocol: image upload, input parsing (+ tests) |
| `zig/src/image.zig` | RGB framebuffer → JPEG (stb_image_write) |
| `zig/src/render.zig` | text/shape drawing (`font8x8.zig`, public-domain 8×8 font) |
| `zig/src/matrix.zig` | matrix_sim HTTP control client |
| `zig/src/soma.zig` | soma-zig IPC client |
| `zig/src/daemon.zig` | pages, key maps, knob wiring, strip layouts, main loop |
| `zig/src/main.zig` | CLI (`run` + dev commands) |

## Backlog

- Config file for key maps / knob assignments (currently hardcoded)
- systemd user service so deckd starts with the session
- Live mirror of the matrix framebuffer on the strip (frames are on
  `ws://:8888` from matrix_server)
