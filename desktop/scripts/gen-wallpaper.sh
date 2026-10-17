#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Generate the placeholder ZeeOS wallpaper (SVG gradient from the palette). No art is committed.
# Usage: gen-wallpaper.sh <root> [light|dark]   (writes <root>/usr/share/wallpapers/ZeeOS/...)
# DRY_RUN=1 prints the target path and writes nothing. Not installer-disk: writes only below <root>.
set -euo pipefail
root=${1:?usage: gen-wallpaper.sh <root> [light|dark]}
variant=${2:-light}
case $variant in
  light) c1='#7aa7f0' c2='#e4e7ed' ;;
  dark)  c1='#1d2a4a' c2='#181a1f' ;;
  *) echo "unknown variant: $variant" >&2; exit 2 ;;
esac
dir=$root/usr/share/wallpapers/ZeeOS/contents/images
out=$dir/3840x2160.svg
if [[ ${DRY_RUN:-0} == 1 ]]; then echo "would write $out"; exit 0; fi
mkdir -p "$dir"
cat > "$out" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="3840" height="2160" viewBox="0 0 3840 2160">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="$c1"/><stop offset="1" stop-color="$c2"/>
  </linearGradient></defs>
  <rect width="3840" height="2160" fill="url(#g)"/>
</svg>
SVG
cat > "$root/usr/share/wallpapers/ZeeOS/metadata.json" <<'JSON'
{"KPlugin":{"Id":"ZeeOS","Name":"ZeeOS","License":"GPL-3.0-or-later"}}
JSON
echo "wrote $out"
