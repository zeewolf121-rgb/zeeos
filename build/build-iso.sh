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
# Live desktop overlay (owned by desktop-shell): copied into the image root, never edited here.
mkdir -p "$desc/root"
cp -a "$root/desktop/live/overlay/." "$desc/root/"
# Hardening overlay (owned by security-hardener, ADR-0012): copied as-is, never edited here;
# skipped while absent (P5-2 adds it).
if [[ -d "$root/security/overlay" ]]; then cp -a "$root/security/overlay/." "$desc/root/"; fi
# ZeeOS wallpapers (owned by theme-designer): every Plasma wallpaper package in branding/wallpapers/
# (a directory with a metadata.json; src/ holds the generator and is not shipped).
mkdir -p "$desc/root/usr/share/wallpapers"
for pkg in "$root"/branding/wallpapers/*/metadata.json; do
  cp -a "$(dirname "$pkg")" "$desc/root/usr/share/wallpapers/"
done
# Calamares installer config and zee-* modules (owned by installer-engineer); skipped while absent.
"$root/build/stage-installer.sh" "$root" "$desc/root"
# Escape a value for use inside an XML attribute and as a sed replacement (| delimiter).
xml_esc() { local v="${1//&/&amp;}"; v="${v//\"/&quot;}"; printf '%s' "${v//</&lt;}"; }
xml_sed() { xml_esc "$1" | sed 's/[\\&|]/\\&/g'; }
# kiwi resolves file:// includes against its cwd, not the description dir: make the path absolute.
sed -i "s|<include from=\"file://|<include from=\"file://$(xml_sed "$desc")/|" "$desc/config.xml"
# Package source (ADR-0008). Default: the closure repo built from packages.lock is the ONLY repo.
# ZEEOS_UNPINNED=1 is a developer opt-out onto the live mirrors (CI and releases never set it).
lock="$src/packages.lock"
unpinned=0
if [[ "${ZEEOS_UNPINNED:-0}" == 1 ]]; then
  unpinned=1
  # shellcheck source=build/pin/lib.sh
  source "$root/build/pin/lib.sh"
  cp "$src/repos-unpinned.xml" "$desc/repos.xml"
  # A local `make rpms` result (unsigned, development only) joins the live mirrors.
  zdir=""; [[ ! -f "$out/zeeos/repodata/repomd.xml" ]] || zdir="$(xml_esc "$out/zeeos")"
  pin_inject_zeeos_repo "$desc/repos.xml" "$zdir"
  echo "WARNING: ZEEOS_UNPINNED=1: building from live Fedora mirrors; the output is NOT reproducible" >&2
else
  closure="${ZEEOS_CLOSURE_DIR:-$out/closure}"
  if [[ "${DRY_RUN:-0}" != 1 ]]; then
    if [[ "${ZEEOS_CLOSURE_REBUILD:-0}" == 1 ]]; then "$root/build/pin/fetch.sh" "$arch" "$closure"
    elif [[ -z "${ZEEOS_CLOSURE_DIR:-}" ]]; then "$root/build/pin/pull.sh" "$arch" "$closure"
    fi
    [[ -f "$closure/repodata/repomd.xml" ]] || { echo "no closure repo in $closure" >&2; exit 1; }
  fi
  # shellcheck source=build/pin/lib.sh
  source "$root/build/pin/lib.sh"
  zdir=""
  if pin_lock_has_zeeos "$lock"; then
    zdir="$closure/zeeos"
    if [[ "${DRY_RUN:-0}" != 1 ]]; then
      if [[ "${ZEEOS_CLOSURE_REBUILD:-0}" == 1 ]]; then
        # Explicit rebuild (ADR-0011): identities must match the lock; bytes may differ. Only the
        # locked files are staged into the closure.
        rm -rf "$out/rpms-rebuild" "$zdir"; mkdir -p "$zdir"
        ZEEOS_RPMS_CHECK=1 bash "$root/build/rpms/build.sh" "$arch" "$out/rpms-rebuild"
        while read -r n evra _; do cp "$out/rpms-rebuild/zeeos/$(pin_rpm_file "$n" "$evra")" "$zdir/"
        done < <(pin_lock_lines "$lock" zeeos-rebuild; pin_lock_lines "$lock" zeeos-rebuild-src)
        createrepo_c --quiet "$zdir"
        pin_verify_zeeos "$lock" "$zdir" identity-only || { echo "ZeeOS rebuild does not match $lock" >&2; exit 1; }
      else
        # Fail closed BEFORE kiwi: the zeeos-rebuild repo has no RPM signature check (ADR-0011 interim).
        pin_verify_zeeos "$lock" "$zdir" || { echo "ZeeOS RPMs in $zdir do not match $lock; refusing to build" >&2; exit 1; }
        [[ -f "$zdir/repodata/repomd.xml" ]] || { echo "no zeeos repo metadata in $zdir" >&2; exit 1; }
      fi
    fi
  fi
  sed "s|@CLOSURE_DIR@|$(xml_sed "$closure")|" "$src/repos-pinned.xml" >"$desc/repos.xml"
  [[ -z "$zdir" ]] || zdir="$(xml_esc "$zdir")"
  pin_inject_zeeos_repo "$desc/repos.xml" "$zdir"
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
# P2-1: Fedora branding must not ship in the image.
if grep -qE '^fedora-logos' "$out/packages.list" 2>/dev/null; then
  echo "Fedora branding package found in the image:" >&2
  grep -E '^fedora-logos' "$out/packages.list" >&2
  exit 1
fi
# Pinned builds must contain exactly the locked packages (identities; sha256 only matters at fetch).
if (( ! unpinned )); then
  # shellcheck source=build/pin/lib.sh
  source "$root/build/pin/lib.sh"
  # comm (coreutils), not diff: the build container has no diffutils. Both sides are LC_ALL=C sorted.
  # Lines: "-<identity>" only in the lock, "+<identity>" only in the image.
  LC_ALL=C comm -3 <(pin_lock_identities "$lock") <(pin_identities <"$out/packages.list") \
    | sed -e 's/^\t/+/' -e '/^+/!s/^/-/' >"$out/lock-vs-packages.diff"
  if [[ -s "$out/lock-vs-packages.diff" ]]; then
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
