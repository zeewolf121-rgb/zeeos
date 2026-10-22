#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fixture test of tests/imgdiff_gate.py: identical passes, changed panel fails, clock change passes.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/base" "$tmp/shots"
gate() { python3 -I tests/imgdiff_gate.py "$tmp/base" "$tmp/shots"; }
# paint FILE X Y W H: write a 100x50 grey PPM with an optional white rectangle.
paint() {
  python3 -I -c '
import sys
f, x, y, w, h = sys.argv[1], *map(int, sys.argv[2:6])
W, H = 100, 50
px = bytearray([60]) * (W * H * 3)
for r in range(y, y + h):
    for c in range(x, x + w):
        px[(r * W + c) * 3 : (r * W + c) * 3 + 3] = b"\xff\xff\xff"
open(f, "wb").write(b"P6\n%d %d\n255\n" % (W, H) + bytes(px))
' "$@"
}
paint "$tmp/base/light.ppm" 0 0 0 0
printf '# clock, bottom right\nlight -20 -10 20 10\n' > "$tmp/base/masks.txt"

paint "$tmp/shots/screenshot-light.ppm" 0 0 0 0
out=$(gate); grep -q '^light pass' <<<"$out" || { echo "FAIL: identical image: $out" >&2; exit 1; }

paint "$tmp/shots/screenshot-light.ppm" 85 42 10 5   # inside the clock mask
out=$(gate); grep -q '^light pass' <<<"$out" || { echo "FAIL: clock change: $out" >&2; exit 1; }

paint "$tmp/shots/screenshot-light.ppm" 0 0 100 10   # a panel
if out=$(gate); then echo "FAIL: changed panel passed: $out" >&2; exit 1; fi
grep -q '^light fail' <<<"$out" || { echo "FAIL: changed panel: $out" >&2; exit 1; }

# A step without a baseline is skipped.
paint "$tmp/shots/screenshot-dark.ppm" 0 0 100 50
rm "$tmp/base/light.ppm"
out=$(gate); grep -q '^dark skip' <<<"$out" || { echo "FAIL: no-baseline step: $out" >&2; exit 1; }
echo "imgdiff_gate_test ok"
