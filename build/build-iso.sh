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
# kiwi resolves file:// includes against its cwd, not the description dir: make the path absolute.
sed -i "s|<include from=\"file://|<include from=\"file://$desc/|" "$desc/config.xml"
# Repo snapshot pinning: ZEEOS_SNAPSHOT_URL (a dated mirror root) replaces the mirror metalinks.
if [[ -n "${ZEEOS_SNAPSHOT_URL:-}" ]]; then
  sed -i -E \
    -e 's| sourcetype="metalink"||' \
    -e "s|https://mirrors.fedoraproject.org/metalink\?repo=fedora-44&amp;arch=[a-z0-9_]+|$ZEEOS_SNAPSHOT_URL/releases/44/Everything/$arch/os|" \
    -e "s|https://mirrors.fedoraproject.org/metalink\?repo=updates-released-f44&amp;arch=[a-z0-9_]+|$ZEEOS_SNAPSHOT_URL/updates/44/Everything/$arch|" \
    "$desc/config.xml"
else
  echo "WARNING: repos not pinned to a snapshot (set ZEEOS_SNAPSHOT_URL)" >&2
fi
echo "staged description in $desc (SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)"
[[ "${DRY_RUN:-0}" == 1 ]] && exit 0

if [[ "${ZEEOS_IN_CONTAINER:-0}" == 1 ]]; then run=(); else run=(sudo -E); fi
"${run[@]}" "$(command -v kiwi-ng)" --type iso system build \
  --description "$desc" --target-dir "$out/image"
pk="$(find "$out/image" -name '*.packages' | head -1)"
[[ -n "$pk" ]] && sort "$pk" >"$out/packages.list"
iso="$(find "$out/image" -name '*.iso' | head -1)"
[[ -n "$iso" ]] || { echo "kiwi produced no ISO" >&2; exit 1; }
size=$(stat -c %s "$iso")
echo "ISO: $iso ($size bytes)"
(( size < 4 * 1024 * 1024 * 1024 )) || { echo "ISO exceeds 4 GB" >&2; exit 1; }
xorriso -indev "$iso" -report_el_torito as_mkisofs | tee "$out/eltorito.txt"
# as_mkisofs lists the EFI boot image as an `-e` entry (platform 0xEF); the appended ESP
# partition shows up by its GPT type GUID, not by the word "efi".
grep -qiE '^-e |efi|28732ac11ff8d211ba4b00a0c93ec93b' "$out/eltorito.txt" \
  || { echo "no El Torito EFI entry" >&2; exit 1; }
grep -q 'isohybrid\|partition_offset\|appended_part_as_gpt' "$out/eltorito.txt" \
  || echo "WARNING: isohybrid markers not found in report" >&2
