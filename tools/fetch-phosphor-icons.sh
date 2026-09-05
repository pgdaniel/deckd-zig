#!/bin/sh
# Regenerates assets/icons/*.png from Phosphor Icons (MIT license —
# https://github.com/phosphor-icons/core), one per default key/button in
# config.zig's default_*_keys arrays. Re-run this after changing the
# mapping below; it's not part of `zig build` and nothing imports it
# automatically — these are just the icon paths the sample config in
# README.md and ~/.config/deckd/config.json point "icon" at, a starting
# point for anyone wiring up their own deckd.
#
# Each entry is "<output-name> <phosphor-icon-name>" — the icon name is
# looked up in the "bold" weight (best legibility at 80x80/120x120 key
# size); see https://phosphoricons.com to browse the full set and its
# weights. Picks, and why (guesses where nothing is an exact match):
#
#   weather  cloud-sun           literal match
#   high     thermometer-hot     "high temp"; plain thermometer has no
#                                 high/low distinction of its own
#   clock    clock               literal match
#   aqi      gauge               reads as "an index reading", closest
#                                 Phosphor has to an actual AQI glyph
#   humid    drop                a plain raindrop reads clearer at key
#                                 size than the segmented drop-half
#   spectr   waveform            vertical bars of varying height — the
#                                 closest match to a spectrum-analyzer
#                                 display (equalizer is sliders, not bars)
#   groove   music-notes         generic music; no "chillout" glyph exists
#   drone    planet              SomaFM Drone Zone is ambient/deep-space;
#                                 paired with deep below, needs to look
#                                 different from it
#   defcon   skull                DEF CON (the hacker con) trades on skull
#                                 imagery
#   agent    detective           SomaFM Secret Agent; Phosphor actually has
#                                 a detective glyph, direct hit
#   lush     flower-lotus        "lush" as in flora, nothing more specific
#   deep     moon-stars          SomaFM Deep Space One; paired with drone
#                                 above, night-sky rather than orbital
#   office   lightbulb           plain bulb for the general light toggle
#   white    lightbulb-filament  a visibly different bulb glyph, since this
#                                 is a second, distinct light key
#   terminal terminal            literal match; the plain glyph reads
#                                 cleaner at key size than terminal-window's
#                                 extra frame outline
#
# Only covers the keys with a label in config.zig's defaults — MQTT slots
# 3-7 (and either model's unused trailing slots) have no icon of their own
# to guess at.
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
out_dir="$repo_root/assets/icons"
mkdir -p "$out_dir"

icons="
weather cloud-sun
high thermometer-hot
clock clock
aqi gauge
humid drop
spectr waveform
groove music-notes
drone planet
defcon skull
agent detective
lush flower-lotus
deep moon-stars
office lightbulb
white lightbulb-filament
terminal terminal
"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "$icons" | while read -r out_name ph_name; do
  [ -z "$out_name" ] && continue
  svg_url="https://raw.githubusercontent.com/phosphor-icons/core/main/assets/bold/${ph_name}-bold.svg"
  echo "fetching $ph_name -> $out_name.png"
  curl -sL --fail "$svg_url" -o "$tmp/$ph_name.svg"
  # Phosphor SVGs use fill="currentColor" on the root <svg>, meant to
  # inherit CSS color from the embedding page — rsvg-convert doesn't
  # resolve that, so force it to white directly.
  sed 's/fill="currentColor"/fill="#ffffff"/' "$tmp/$ph_name.svg" > "$tmp/$ph_name.white.svg"
  # 256x256, transparent background: deckd's drawIconFit scales to fit and
  # alpha-blends onto the key's own background color, so no fill of our
  # own is drawn here.
  rsvg-convert -w 256 -h 256 "$tmp/$ph_name.white.svg" -o "$out_dir/$out_name.png"
done

echo "done -> $out_dir"
