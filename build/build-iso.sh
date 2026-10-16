#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the ZeeOS live ISO with kiwi-ng. Needs root (loop devices); CI runs it on a full VM.
# Usage: build/build-iso.sh <arch> [out-dir]   (DRY_RUN=1 stages the description only)
set -euo pipefail

arch="${1:?usage: build-iso.sh <arch> [out-dir]}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${2:-$root/out/$arch}"
src="$root/build/arch/$arch"
[[ -f "$src/config.xml" ]] || { echo "no image description for ARCH=$arch" >&2; exit 2; }

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$root" log -1 --format=%ct)}"
export SOURCE_DATE_EPOCH
desc="$out/description"
rm -rf "$desc"
mkdir -p "$desc"
cp -a "$root/build/common/." "$desc/"
cp -a "$src/." "$desc/"
echo "staged description in $desc (SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)"
[[ "${DRY_RUN:-0}" == 1 ]] && exit 0

sudo -E "$(command -v kiwi-ng)" --type iso system build \
  --description "$desc" --target-dir "$out/image"
iso="$(find "$out/image" -name '*.iso' | head -1)"
[[ -n "$iso" ]] || { echo "kiwi produced no ISO" >&2; exit 1; }
size=$(stat -c %s "$iso")
echo "ISO: $iso ($size bytes)"
(( size < 4 * 1024 * 1024 * 1024 )) || { echo "ISO exceeds 4 GB" >&2; exit 1; }
xorriso -indev "$iso" -report_el_torito as_mkisofs | tee "$out/eltorito.txt"
grep -qi 'efi' "$out/eltorito.txt" || { echo "no El Torito EFI entry" >&2; exit 1; }
grep -q 'isohybrid\|partition_offset\|appended_part_as_gpt' "$out/eltorito.txt" \
  || echo "WARNING: isohybrid markers not found in report" >&2
