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
# Escape a value for use inside an XML attribute and as a sed replacement (| delimiter).
xml_sed() { local v="${1//&/&amp;}"; v="${v//\"/&quot;}"; v="${v//</&lt;}"; printf '%s' "$v" | sed 's/[\\&|]/\\&/g'; }
# kiwi resolves file:// includes against its cwd, not the description dir: make the path absolute.
sed -i "s|<include from=\"file://|<include from=\"file://$(xml_sed "$desc")/|" "$desc/config.xml"
# Package source (ADR-0008). Default: the closure repo built from packages.lock is the ONLY repo.
# ZEEOS_UNPINNED=1 is a developer opt-out onto the live mirrors (CI and releases never set it).
lock="$src/packages.lock"
unpinned=0
if [[ "${ZEEOS_UNPINNED:-0}" == 1 ]]; then
  unpinned=1
  cp "$src/repos-unpinned.xml" "$desc/repos.xml"
  echo "WARNING: ZEEOS_UNPINNED=1: building from live Fedora mirrors; the output is NOT reproducible" >&2
else
  closure="${ZEEOS_CLOSURE_DIR:-$out/closure}"
  if [[ "${DRY_RUN:-0}" != 1 ]]; then
    if [[ "${ZEEOS_CLOSURE_REBUILD:-0}" == 1 ]]; then "$root/build/pin/fetch.sh" "$arch" "$closure"
    elif [[ -z "${ZEEOS_CLOSURE_DIR:-}" ]]; then "$root/build/pin/pull.sh" "$arch" "$closure"
    fi
    [[ -f "$closure/repodata/repomd.xml" ]] || { echo "no closure repo in $closure" >&2; exit 1; }
  fi
  sed "s|@CLOSURE_DIR@|$(xml_sed "$closure")|" "$src/repos-pinned.xml" >"$desc/repos.xml"
fi
rm -f "$desc/repos-pinned.xml" "$desc/repos-unpinned.xml"
echo "staged description in $desc (SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH, unpinned=$unpinned)"
[[ "${DRY_RUN:-0}" == 1 ]] && exit 0

if [[ "${ZEEOS_RESOLVE_ONLY:-0}" == 1 ]]; then
  # make pin-packages: install into a root only, then list it (same fields as kiwi's .packages).
  [[ "${ZEEOS_IN_CONTAINER:-0}" == 1 ]] || { echo "ZEEOS_RESOLVE_ONLY runs inside the build container" >&2; exit 2; }
  rm -rf "$out/resolve-root"
  kiwi-ng system prepare --description "$desc" --root "$out/resolve-root"
  rpm --root "$out/resolve-root" -qa --qf '%{NAME}|%{EPOCHNUM}|%{VERSION}|%{RELEASE}|%{ARCH}\n' >"$out/resolved.list"
  rm -rf "$out/resolve-root"
  exit 0
fi

if [[ "${ZEEOS_IN_CONTAINER:-0}" == 1 ]]; then run=(); else run=(sudo -E); fi
"${run[@]}" "$(command -v kiwi-ng)" --type iso system build \
  --description "$desc" --target-dir "$out/image"
pk="$(find "$out/image" -name '*.packages' | head -1)"
[[ -n "$pk" ]] && sort "$pk" >"$out/packages.list"
# Pinned builds must contain exactly the locked packages (identities; sha256 only matters at fetch).
if (( ! unpinned )); then
  # shellcheck source=build/pin/lib.sh
  source "$root/build/pin/lib.sh"
  if ! diff -u <(pin_lock_identities "$lock") <(pin_identities <"$out/packages.list") >"$out/lock-vs-packages.diff"; then
    echo "packages.list does not match $lock (see $out/lock-vs-packages.diff):" >&2
    cat "$out/lock-vs-packages.diff" >&2
    exit 1
  fi
  echo "packages.list matches packages.lock ($(pin_lock_identities "$lock" | wc -l) packages)"
fi
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
