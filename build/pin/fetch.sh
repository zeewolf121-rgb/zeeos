#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Make <dir> hold exactly the RPMs in packages.lock and turn it into a repo (ADR-0008).
# Already-present files are reused. Missing ones come from the Fedora mirrors, then from the signed
# Koji copies; every file must match the locked sha256 and carry a Fedora signature.
# Needs curl, rpm and createrepo_c, so it runs in the build container.
# Usage: build/pin/fetch.sh <arch> <dir>
set -euo pipefail
arch="${1:?usage: fetch.sh <arch> <dir>}"
dir="${2:?usage: fetch.sh <arch> <dir>}"
# shellcheck source=build/pin/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
lock="$(pin_lock "$arch")"
pin_lock_resolved "$lock" || { echo "$lock has no packages: run 'make pin-packages ARCH=$arch'" >&2; exit 1; }
mirror="${ZEEOS_MIRROR_URL:-https://dl.fedoraproject.org/pub/fedora/linux}"
koji="${ZEEOS_KOJI_URL:-https://kojipkgs.fedoraproject.org/packages}"
keyid="${ZEEOS_KOJI_KEYID:-6d9f90a6}"   # Fedora 44 signing key id (the signed/<keyid>/ directory)
mkdir -p "$dir"

try() {   # try <url> <dest> <sha256>: download, keep only if the hash matches
  local tmp="$2.part"
  if curl -fsSL --retry 3 -o "$tmp" "$1" && [[ "$(sha256sum "$tmp" | cut -d' ' -f1)" == "$3" ]]; then
    mv "$tmp" "$2"; return 0
  fi
  rm -f "$tmp"; return 1
}

declare -A want=()
while read -r n evra sha src; do
  [[ -n "$n" && "$n" != '#'* ]] || continue
  f="$(pin_rpm_file "$n" "$evra")"; want[$f]=1; dest="$dir/$f"
  if [[ -f "$dest" && "$(sha256sum "$dest" | cut -d' ' -f1)" == "$sha" ]]; then continue; fi
  rm -f "$dest"
  vr="${evra#*:}"; a="${vr##*.}"; vrn="${vr%.*}"; l="${f:0:1}"; l="${l,,}"
  ok=0
  for u in "$mirror/updates/44/Everything/$a/Packages/$l/$f" \
           "$mirror/releases/44/Everything/$a/os/Packages/$l/$f" \
           "$koji/${src:-$n}/${vrn%-*}/${vrn##*-}/data/signed/$keyid/$a/$f"; do
    if try "$u" "$dest" "$sha"; then ok=1; break; fi
  done
  (( ok )) || { echo "cannot fetch $f (sha256 $sha): gone from mirrors and Koji; see ADR-0008 access paths" >&2; exit 1; }
done <"$lock"

# Drop anything not in the lock (stale files from an older lock), then verify and index.
for p in "$dir"/*.rpm; do [[ -n "${want[$(basename "$p")]:-}" ]] || rm -f "$p"; done
pin_check_signatures "$dir"/*.rpm
rm -rf "$dir/repodata"
createrepo_c --quiet "$dir"
echo "closure repo for $arch ready in $dir: ${#want[@]} RPMs"
