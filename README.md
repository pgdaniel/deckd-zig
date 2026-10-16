# deckd-zig

A Linux daemon for the **Elgato Stream Deck Plus**, written from scratch in
Zig over raw hidraw — no libraries, no official SDK. It is a generic,
config-driven **MQTT controller**: keys, knobs and the touch strip publish
topics, and key faces, borders and strip text are drawn from topics it
subscribes to. Nothing about any particular device is built in — matrix_sim,
soma-zig, lights, whatever speaks MQTT, is wired up in `config.json`.

Everything on the device works: the 8 LCD keys (120×120 JPEG each), the
800×100 touch strip, and the 4 rotary encoder knobs (turn + push). The
6-key Stream Deck Mini is supported too (no strip, no knobs).

## Building

Pinned to zig 0.16.0 (see `.tool-versions`):

```
cd zig
zig build          # produces zig-out/bin/deckd
zig build test     # protocol parser, MQTT packet, store and config tests
```

Vendored: `stb_image_write.h` for JPEG encoding (keys/strip only accept JPEG),
`stb_image.h` for decoding icon files, `stb_truetype.h` for fonts.

## Running

```
deckd run                          # uses ~/.config/deckd/config.json
```

The device is auto-discovered by scanning `/sys/class/hidraw/*/device/uevent`
for VID `0fd9` / PID `0084`; `--device /dev/hidrawN` overrides. Your user needs
rw on the hidraw node (logind's `uaccess` tag usually covers the active
session; otherwise a udev rule).

The broker connection is persistent and reconnects forever; while it's down
the strip shows `MQTT OFFLINE` and presses are logged and dropped. The
display only redraws what changed (per-key and strip signatures), so it's
quiet when idle.

## Configuration

`~/.config/deckd/config.json` — everything is optional. See
[`examples/config.json`](examples/config.json) for a full one (a MATRIX page
and a SOMA page driving [matrix_sim](../matrix_sim) and
[soma-zig](../soma-zig)).

```json
{
  "mqtt_host": "192.168.1.10",
  "mqtt_port": 1883,
  "mqtt_user": "", "mqtt_pass": "",
  "topic_prefix": "deckd",
  "brightness": 80,
  "font_path": "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Bold.ttf",
  "font_size_key": 22, "font_size_strip": 30,
  "pages": [
    { "name": "LIGHTS", "color": "ffc850",
      "keys": [
        { "label": "LT ON", "color": "ffc850",
          "topic": "home/lights/set", "payload": "ON",
          "active_topic": "home/lights/state", "active_value": "ON" },
        { "label": "{home/temp}C", "color": "64a0ff" }
      ],
      "strip": [ "{@page}", "lights: {home/lights/state}" ],
      "dials": [ null, null, { "turn_topic": "home/dimmer", "turn_mode": "value",
                                "turn_min": 0, "turn_max": 100, "turn_step": 5 } ]
    }
  ],
  "dials": [ null, null, null, { "turn_action": "brightness", "press_action": "page" } ]
}
```

`mqtt_host` must be a literal IP (or `localhost`); no DNS, no TLS — LAN
brokers only. With no config at all you get one blank page whose only live
controls are knob 4 (brightness / page).

### Pages and keys

`pages` (up to 8) each swap what the keys and strip show; cycle them with a
dial's `press_action: "page"` (knob 4 by default) or by publishing to
`<prefix>/page/set`. On the Mini, which has no knobs, the last key is
reserved as the page button.

A key (`keys[i]`, up to 8 per page, patched by index):

| Field | Meaning |
|---|---|
| `label`, `icon`, `color` | face: text (a template), or an icon file, on a dim `color` background |
| `topic`, `payload`, `retain` | published when pressed; empty `topic` = publish nothing |
| `active_topic`, `active_value` | white border while that topic's latest message equals the value (empty value = `ON`/`1`/`true`) |

### Page backgrounds

A page may set `"background_topic": "some/topic"`. That topic's message is an
image (raw JPEG/PNG bytes, up to ~190 KB; an empty message clears it).
deckd center-crops it across the whole key grid, so the keys act as one
screen, and dims it behind the labels and icons. One background topic per
config. Any publisher works; the Spotify bridge sends the album cover.

### Templates

`label` and each of a page's `strip` lines (up to 3: a large line, then two
small ones) may contain `{some/topic}`, replaced by that topic's latest
message (`-` until one arrives). `{@page}` is the current page name. deckd
subscribes to every topic it finds in the config. Retained messages make
state show up immediately on connect.

### Dials

A dial (`dials[i]`, global; a page's own `dials[i]` replaces it while that
page shows, `null` = keep the global one):

| Field | Meaning |
|---|---|
| `turn_topic`, `turn_step` | each click publishes there |
| `turn_mode` | `"delta"` (default): payload is `turn_step × clicks`, signed. `"value"`: a running total from `turn_start`, clamped to `turn_min`..`turn_max` |
| `press_topic`, `press_payload` | published on push |
| `turn_action` / `press_action` | built-ins instead of topics: `"brightness"` / `"page"` |

Swiping the strip and every raw input are also published — see below.

Icons: a key's `"icon"` is an absolute path (no `~` expansion — same
convention as `font_path`); when set, it's drawn on the key (scaled to fit,
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

`assets/icons/` has ready-made icons for the keys in `examples/config.json` (from
[Phosphor Icons](https://phosphoricons.com), MIT-licensed — bold weight,
white on transparent, 256×256) — add an `"icon": "/abs/path/to/assets/icons/x.png"`
to a key to use one. `tools/fetch-phosphor-icons.sh` regenerates them and documents
the exact icon chosen for each key (and why, where nothing was a literal
match) — re-run it if you change the mapping. It needs `curl` and
`rsvg-convert` and fetches from `raw.githubusercontent.com` — it's a
maintainer tool, not part of `zig build`.

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

## Topics

Published under `topic_prefix` (default `deckd`), QoS 0:

| Topic | Payload |
|---|---|
| `deckd/status` | `online` / `offline` (retained; `offline` is the last-will) |
| `deckd/page` | current page name (retained) |
| `deckd/key/<n>` | `press` (n is 0-based, any page) |
| `deckd/dial/<n>/turn` | signed click count |
| `deckd/dial/<n>/press` | `press` |
| `deckd/strip/swipe` | `left` / `right` |
| `deckd/strip/tap` | `x,y` |

Subscribed control topics:

| Topic | Effect |
|---|---|
| `deckd/page/set` | switch page by name or 0-based index |
| `deckd/brightness/set` | 0-100 |

Plus whatever topics your config's templates and `active_topic`s mention.

### Companion projects

Both of these publish retained state and accept commands over MQTT; the
example config uses exactly these topics.

- **[matrix_sim](../matrix_sim)** (`mqtt_control.py`, device name `display1`):
  `display1/<screen>` switches screen, `display1/next`, `display1/auto`
  (`on`/`off`/`toggle`), `display1/message`; state in
  `display1/state/screen`, `display1/state/auto`, `display1/state/screens`.
- **[soma-zig](../soma-zig)** (set `SOMA_MQTT_HOST`, optionally
  `SOMA_MQTT_PORT`/`_USER`/`_PASS`/`_TOPIC`): `soma/cmd` takes any soma
  command line (`play groovesalad`, `toggle`, `mute`, `viz next`, ...),
  `soma/vol/set`, `soma/vol/adj` and `soma/surf` suit a dial's `turn_topic`;
  state in `soma/state/{playing,channel,channel_id,track,volume}` and
  `soma/status`.

- **Spotify** (`bridges/spotify-mqtt.py`, any Linux PC): a stdlib-only
  script that bridges any MPRIS player (Spotify desktop, `spotifyd`) to MQTT
  — needs only `python3` and systemd's `busctl`. Install one per PC:
  `cp bridges/spotify-mqtt.py ~/.local/bin/spotify-mqtt`, put
  `SPOTIFY_MQTT_HOST=<broker>` in `~/.config/spotify-mqtt.env`, and enable
  `bridges/spotify-mqtt.service` as a user unit. Each PC publishes
  `spotify/<hostname>/state/{playing,artist,track,album,volume}` and takes
  commands on `spotify/<hostname>/{cmd,skip,vol/set,vol/adj}`. The *shared*
  topics (`spotify/cmd`, `spotify/state/*`, ...) follow whichever PC is
  playing (or played last), so one SPOTIFY page controls whichever machine
  has music on; `spotify/state/host` says which. The album cover goes out as
  JPEG bytes on `.../state/art`; give the SPOTIFY page
  `"background_topic": "spotify/state/art"` to show it behind the keys. See
  the script header.

### Config GUI

`deckd-config` (GTK4) still edits the old pre-MQTT schema and is **not built
by default** (`zig build -Dconfig-gui=true` builds it); a rewrite for pages
is on the backlog. Edit `config.json` by hand for now.

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

## Files

| File | Purpose |
|---|---|
| `zig/src/hid.zig` | hidraw open/discovery, feature reports, report I/O |
| `zig/src/deck.zig` | wire protocol: image upload, input parsing (+ tests) |
| `zig/src/image.zig` | RGB framebuffer → JPEG (stb_image_write), icon loading |
| `zig/src/render.zig` | text/shape drawing (`font8x8.zig`, public-domain 8×8 font) |
| `zig/src/ttf.zig` | TrueType text via stb_truetype |
| `zig/src/mqtt.zig` | MQTT 3.1.1 client: long-lived `Session` + one-shot publish (QoS 0, no TLS) |
| `zig/src/store.zig` | latest message per topic + `{topic}` template expansion |
| `zig/src/config.zig` | `~/.config/deckd/config.json` loading (pages, keys, dials) |
| `zig/src/daemon.zig` | event loop: input → publishes, topics → key/strip drawing |
| `zig/src/main.zig` | CLI (`run` + dev commands) |
| `zig/src/config_gui.zig` | `deckd-config` GTK4 editor (old schema; opt-in build) |
| `examples/config.json` | MATRIX, SOMA and SPOTIFY pages for the companion projects |
| `bridges/` | `spotify-mqtt.py` (+ user unit): MPRIS <-> MQTT bridge, one per Linux PC |
| `assets/icons/` | ready-made Phosphor icons, one per example key |
| `tools/fetch-phosphor-icons.sh` | regenerates `assets/icons/` |
| `systemd/deckd.service` | user service for running at login |
| `packaging/` | PKGBUILD (Arch) and SlackBuild (Slackware) |

## Backlog

- Rewrite `deckd-config` for the pages schema
- DNS for `mqtt_host`, TLS
- Per-band auto-gain in soma-zig's visualizer (high bands read low)
