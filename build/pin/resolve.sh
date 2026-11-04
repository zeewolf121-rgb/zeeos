#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Resolve the full package closure against the live Fedora repos and rewrite packages.lock (ADR-0008).
# Runs INSIDE the build container (needs kiwi-ng, dnf5, rpm): `make pin-packages` calls it via run.sh.
# Leaves the lock (timestamp included) untouched when nothing semantic changed.
# Usage: build/pin/resolve.sh <arch> [out-dir]     out-dir receives rpms/ for publish.sh
set -euo pipefail
arch="${1:?usage: resolve.sh <arch> [out-dir]}"
# shellcheck source=build/pin/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
out="${2:-$PIN_ROOT/out/$arch}"
mkdir -p "$out"   # resolver metadata is written before build-iso.sh stages (and would create) it
lock="$(pin_lock "$arch")"

# Hold mode (ZEEOS_PIN_HOLD=1, `make pin-packages HOLD=1`, #310): build/pin/hold.sh staged the current lock's
# closure in $out/held. Its repo outranks Fedora's during the kiwi resolve, so locked packages keep their
# versions and Fedora only supplies new names; the locked RPMs are copied from the held closure (superseded
# builds are gone from the mirrors), and ZeeOS rebuilds come from it too (no `make rpms`). Fail closed below
# if any locked identity changes or disappears.
hold=0; held="$out/held"; hl="$out/held.lock"
if [[ "${ZEEOS_PIN_HOLD:-0}" == 1 ]]; then
  hold=1
  [[ -f "$hl" && -f "$held/repodata/repomd.xml" ]] || { echo "hold mode needs build/pin/hold.sh first (make pin-packages HOLD=1 runs it)" >&2; exit 1; }
  [[ ! -f "$out/zeeos.lock" ]] || { echo "hold mode: remove $out/zeeos.lock (a 'make rpms' result); ZeeOS rebuilds come from the held closure" >&2; exit 1; }
  if pin_lock_has_zeeos "$hl"; then
    { echo "# tools-image=pinned"; pin_lock_lines "$hl" zeeos-rebuild; pin_lock_lines "$hl" zeeos-rebuild-src; } >"$out/zeeos.lock"
    rm -rf "$out/zeeos"; cp -a "$held/zeeos" "$out/zeeos"
    pin_verify_zeeos "$hl" "$out/zeeos" || { echo "held closure's zeeos/ does not match the held lock" >&2; exit 1; }
  fi
  export ZEEOS_HOLD_DIR="$held"
fi

# ZeeOS rebuilds (ADR-0011): `make rpms` leaves $out/zeeos and $out/zeeos.lock; kiwi sees them as a second repo.
zl="$out/zeeos.lock"
if [[ -f "$zl" ]]; then
  [[ "$(pin_lock_header "$zl" tools-image)" == pinned ]] || {
    echo "$zl was built with an unpinned tools image: publish the tools image (build/container/publish.sh) and rerun 'make rpms ARCH=$arch'" >&2
    exit 1; }
  [[ -f "$out/zeeos/repodata/repomd.xml" ]] || { echo "$zl exists but $out/zeeos has no repo: rerun 'make rpms ARCH=$arch'" >&2; exit 1; }
fi

# 1. Let kiwi itself resolve (prepare only) so the lock matches what a real build installs.
resolve_profile() {   # resolve_profile <live|oem> <ids-out>
  ZEEOS_UNPINNED=1 ZEEOS_RESOLVE_ONLY=1 ZEEOS_PROFILE="$1" "$PIN_ROOT/build/build-iso.sh" "$arch" "$out"
  pin_identities <"$out/resolved.list" >"$2"
  [[ -s "$2" ]] || { echo "kiwi resolved no packages for the $1 profile" >&2; exit 1; }
}
# An arch whose description has an oem profile (aarch64, #277) is resolved twice and locked as the
# union. The identities only the oem disk installs are recorded as "# oem-only=" header lines so the
# live ISO check can tolerate exactly those; the oem check needs every disk package locked.
# The two resolves are minutes apart: if the live mirrors moved in between, a package resolves to two
# versions and only one is downloadable. Resolve again (fail closed after 3 tries) instead of locking skew.
: >"$out/oem-only.ids"
if grep -q '<profile name="oem"' "$PIN_ROOT/build/arch/$arch/config.xml"; then
  for try in 1 2 3; do
    resolve_profile live "$out/resolved.live.ids"
    resolve_profile oem "$out/resolved.oem.ids"
    # Same name.arch with a different version in the two sets = skew.
    LC_ALL=C sort -u "$out/resolved.live.ids" "$out/resolved.oem.ids" \
      | awk '{ a = $2; sub(/^.*\./, "", a); k = $1 "." a; c[k]++; l[k] = l[k] " " $2 }
             END { for (k in c) if (c[k] > 1) print k ":" l[k] }' >"$out/skew.txt"
    [[ ! -s "$out/skew.txt" ]] && break
    echo "live and oem resolves disagree on versions (try $try of 3):" >&2; cat "$out/skew.txt" >&2
    [[ "$try" != 3 ]] || { echo "repo metadata kept moving; rerun make pin-packages" >&2; exit 1; }
  done
  LC_ALL=C comm -13 "$out/resolved.live.ids" "$out/resolved.oem.ids" >"$out/oem-only.ids"
  LC_ALL=C sort -u "$out/resolved.live.ids" "$out/resolved.oem.ids" >"$out/resolved.ids"
else
  resolve_profile live "$out/resolved.ids"
fi
# Fail closed: a package ZeeOS rebuilds (a locked build/rpms/<name>/source.lock) must never be
# pinned as Fedora's stock build, e.g. calamares with setxkbmap (ADR-0011). Without zeeos.lock
# kiwi only saw Fedora, so stop instead of silently locking the stock RPM.
if [[ ! -f "$zl" ]]; then
  pin_check_no_stock_rebuilds "$out/resolved.ids" "$PIN_ROOT/build/rpms" \
    || { echo "  run 'make rpms ARCH=$arch' before 'make pin-packages'" >&2; exit 1; }
fi
# Split: identities that are ZeeOS rebuilds come from $out/zeeos, everything else from Fedora.
: >"$out/zeeos.ids"
if [[ -f "$zl" ]]; then
  pin_lock_identities "$zl" >"$out/zeeos-built.ids"
  LC_ALL=C comm -12 "$out/resolved.ids" "$out/zeeos-built.ids" >"$out/zeeos.ids"
  LC_ALL=C comm -23 "$out/resolved.ids" "$out/zeeos.ids" >"$out/fedora.ids"
else
  cp "$out/resolved.ids" "$out/fedora.ids"
fi

if (( hold )); then
  # Additions only: every held identity still resolves to the same version, and no name.arch has two versions.
  pin_lock_identities "$hl" >"$out/held-all.ids"
  if [[ -n "$(LC_ALL=C comm -23 "$out/held-all.ids" "$out/resolved.ids")" ]]; then
    echo "hold mode: held packages missing from the new resolve (versions moved or dropped):" >&2
    LC_ALL=C comm -23 "$out/held-all.ids" "$out/resolved.ids" >&2; exit 1
  fi
  dups="$(awk '{ a = $2; sub(/^.*\./, "", a); c[$1 "." a]++ } END { for (k in c) if (c[k] > 1) print k }' "$out/resolved.ids")"
  [[ -z "$dups" ]] || { echo "hold mode: packages resolved at two versions:" >&2; echo "$dups" >&2; exit 1; }
fi

# 2. Download every resolved RPM (dnf checks repo signatures), then hash and verify them.
rpms="$out/rpms"
rm -rf "$rpms"; mkdir -p "$rpms"
specs=()
while read -r n evra; do specs+=("$n-$evra"); done <"$out/fedora.ids"   # dnf spec: name-epoch:version-release.arch
if (( hold )); then
  # Locked identities are copied from the held closure and checked against the lock's sha256; only new ones are downloaded.
  pin_lock_lines "$hl" fedora | awk '{ print $1, $2 }' | LC_ALL=C sort -u >"$out/held-fedora.ids"
  LC_ALL=C comm -12 "$out/fedora.ids" "$out/held-fedora.ids" >"$out/kept.ids"
  LC_ALL=C comm -23 "$out/fedora.ids" "$out/held-fedora.ids" >"$out/new.ids"
  while read -r n evra; do
    f="$(pin_rpm_file "$n" "$evra")"; want="$(pin_lock_lines "$hl" fedora | awk -v n="$n" -v e="$evra" '$1 == n && $2 == e { print $3 }')"
    [[ -f "$held/$f" && "$(sha256sum "$held/$f" | cut -d' ' -f1)" == "$want" ]] || { echo "held closure lacks $f or its sha256 differs from the held lock" >&2; exit 1; }
    cp "$held/$f" "$rpms/"
  done <"$out/kept.ids"
  specs=(); while read -r n evra; do specs+=("$n-$evra"); done <"$out/new.ids"
  echo "hold mode: $(wc -l <"$out/kept.ids") packages kept from the held closure, ${#specs[@]} new"
fi
(( ${#specs[@]} == 0 )) || dnf5 -y download --destdir "$rpms" "${specs[@]}"
pin_check_signatures "$rpms"/*.rpm

# 3. Build the new lock body.
new="$out/packages.lock.new"
while read -r n evra; do
  f="$rpms/$(pin_rpm_file "$n" "$evra")"
  [[ -f "$f" ]] || { echo "downloaded RPM missing for $n $evra: $f" >&2; exit 1; }
  src="$(rpm -qp --qf '%{SOURCERPM}' "$f" | sed -E 's/-[^-]+-[^-]+\.src\.rpm$//')"
  echo "$n $evra $(sha256sum "$f" | cut -d' ' -f1) $src"
done <"$out/fedora.ids" | LC_ALL=C sort >"$new"
# ZeeOS rebuilds actually installed, plus the SRPMs they came from, each with an explicit origin.
if [[ -s "$out/zeeos.ids" ]]; then
  zbin="$out/zeeos-selected.lock"; zsrc="$out/zeeos-selected-src.lock"
  while read -r n evra sha src origin; do
    if grep -qxF "$n $evra" "$out/zeeos.ids"; then echo "$n $evra $sha $src $origin"; fi
  done < <(pin_lock_lines "$zl" zeeos-rebuild) >"$zbin"
  while read -r n evra sha src origin; do
    if grep -q " $src zeeos-rebuild\$" "$zbin"; then echo "$n $evra $sha $src $origin"; fi
  done < <(pin_lock_lines "$zl" zeeos-rebuild-src) >"$zsrc"
  cat "$zbin" "$zsrc" >>"$new"
  LC_ALL=C sort -o "$new" "$new"
  zsel="$out/zeeos-all.lock"; cat "$zbin" "$zsrc" >"$zsel"
  # Stage exactly the locked ZeeOS files as the closure's zeeos/ repo.
  rm -rf "$rpms/zeeos"; mkdir -p "$rpms/zeeos"
  while read -r n evra _; do cp "$out/zeeos/$(pin_rpm_file "$n" "$evra")" "$rpms/zeeos/"; done <"$zsel"
  createrepo_c --quiet "$rpms/zeeos"
fi

# 4. Keep the lock as is unless the package lines changed.
# String compare, not diff: the build container has no diffutils (diff would exit 127 = "changed").
# An unchanged body only counts if the lock also records its closure digest: a refresh whose
# publish was skipped (PUBLISH=0) or failed must publish on the next run, not stop here.
if [[ -f "$lock" && -n "$(pin_lock_header "$lock" closure)" \
      && "$(pin_lock_body "$lock")" == "$(LC_ALL=C sort "$new")" \
      && "$(pin_lock_oem_only "$lock")" == "$(cat "$out/oem-only.ids")" ]]; then
  echo "packages.lock for $arch unchanged"; echo unchanged >"$out/pin.status"; exit 0
fi
{
  echo "# SPDX-License-""Identifier: GPL-3.0-or-later"
  echo "# zeeos packages.lock v1 (ADR-0008). Generated by 'make pin-packages ARCH=$arch'; do not edit."
  echo "# Columns: name epoch:version-release.arch sha256 source-rpm-name [origin: zeeos-rebuild | zeeos-rebuild-src]"
  echo "# release=44"
  echo "# arch=$arch"
  echo "# resolved=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# closure="   # filled in by publish.sh
  while read -r n evra; do echo "# oem-only=$n $evra"; done <"$out/oem-only.ids"
  cat "$new"
} >"$lock"
echo changed >"$out/pin.status"
"$PIN_ROOT/build/pin/fetch.sh" "$arch" "$rpms"   # verify the lock against the files and build the repo
echo "wrote $lock: $(wc -l <"$new") packages"
