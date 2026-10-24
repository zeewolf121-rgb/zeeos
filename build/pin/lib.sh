#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared helpers for the package-pinning scripts (ADR-0008). Source this file; do not run it.
# A package identity is "name epoch:version-release.arch".

PIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Lowercase GHCR owner; override for forks.
# shellcheck disable=SC2034  # used by publish.sh
PIN_OWNER="${ZEEOS_REGISTRY_OWNER:-zeewolf121-rgb}"
# One shared exclusion for packages.list and the lock: the RPM db's imported-key pseudo-packages.
PIN_EXCLUDE='gpg-pubkey'

pin_lock() { echo "$PIN_ROOT/build/arch/$1/packages.lock"; }

# stdin: "name|epoch|version|release|arch[|...]" (kiwi .packages or rpm --qf); stdout: identities.
pin_identities() {
  awk -F'|' -v ex="$PIN_EXCLUDE" '$1 != ex && NF >= 5 {
    e = $2; if (e == "" || e == "(none)") e = 0
    print $1, e ":" $3 "-" $4 "." $5 }' | LC_ALL=C sort -u
}

# Lock columns: name evra sha256 source-rpm-name [origin]. A missing origin means Fedora's own RPM.
# ZeeOS rebuilds (ADR-0011) carry origin "zeeos-rebuild" (binary) or "zeeos-rebuild-src" (their SRPM).
# Identities of a lock file (sha256, source and origin columns dropped). SRPMs are not installable
# packages, so they never count as an identity.
pin_lock_identities() { grep -v '^#' "$1" | awk 'NF >= 3 && $5 != "zeeos-rebuild-src" { print $1, $2 }' | LC_ALL=C sort -u; }

# Lock lines with origin $2 ("fedora" matches lines without an origin column).
pin_lock_lines() {
  grep -v '^#' "$1" | awk -v o="$2" 'NF >= 3 { x = ($5 == "" ? "fedora" : $5); if (x == o) print }'
}

# True when the lock has at least one ZeeOS-rebuilt line (binary or source).
pin_lock_has_zeeos() { [[ -n "$(pin_lock_lines "$1" zeeos-rebuild)$(pin_lock_lines "$1" zeeos-rebuild-src)" ]]; }

# Repository block for the ZeeOS rebuilds in <dir> (ADR-0011 interim trust model): no RPM signature
# check here. pin_verify_zeeos must have passed first. Fedora's repo keeps package_gpgcheck="true".
pin_zeeos_repo_xml() {
  printf '  <repository type="rpm-md" alias="zeeos-rebuild" priority="1" package_gpgcheck="false" repository_gpgcheck="false">\n'
  printf '    <source path="dir://%s"/>\n  </repository>\n' "$1"
}

# Replace the @ZEEOS_REPO@ placeholder line in <repos.xml> with the zeeos-rebuild repo for <dir>,
# or remove it when <dir> is empty (nothing ZeeOS-built in the closure).
pin_inject_zeeos_repo() {
  local xml="$1" dir="${2:-}" block=""
  [[ -z "$dir" ]] || block="$(pin_zeeos_repo_xml "$dir")"
  ZB="$block" awk '/@ZEEOS_REPO@/ { if (ENVIRON["ZB"] != "") print ENVIRON["ZB"]; next } { print }' "$xml" >"$xml.new" && mv "$xml.new" "$xml"
}

# Fail closed unless <dir> holds exactly the ZeeOS-rebuilt RPMs the lock names, byte for byte.
# Checks: every locked file exists and matches its sha256; nothing unlocked sits in <dir>; a rebuilt
# package carries the ".zeeos" release marker and shares no name with a Fedora line (no mixed NEVRA).
# Usage: pin_verify_zeeos <lock> <dir> [identity-only]   (identity-only skips sha256, for ZEEOS_CLOSURE_REBUILD)
pin_verify_zeeos() {
  local lock="$1" dir="$2" idonly="${3:-}" bad=0 n evra sha origin f got
  local -A want=() fed=()
  while read -r n _; do fed[$n]=1; done < <(pin_lock_lines "$lock" fedora)
  while read -r n evra sha _ origin; do
    f="$(pin_rpm_file "$n" "$evra")"; want[$f]=1
    if [[ "$evra" != *.zeeos* ]]; then
      echo "zeeos: $n $evra has no .zeeos release marker" >&2; bad=1
    fi
    if [[ "$origin" == zeeos-rebuild && -n "${fed[$n]:-}" ]]; then
      echo "zeeos: $n is locked both as a Fedora and as a zeeos-rebuild package" >&2; bad=1
    fi
    if [[ ! -f "$dir/$f" ]]; then echo "zeeos: missing $f" >&2; bad=1; continue; fi
    [[ -n "$idonly" ]] && continue
    got="$(sha256sum "$dir/$f" | cut -d' ' -f1)"
    [[ "$got" == "$sha" ]] || { echo "zeeos: $f sha256 $got does not match the lock ($sha)" >&2; bad=1; }
  done < <(pin_lock_lines "$lock" zeeos-rebuild; pin_lock_lines "$lock" zeeos-rebuild-src)
  for f in "$dir"/*.rpm; do
    [[ -e "$f" ]] || continue
    [[ -n "${want[$(basename "$f")]:-}" ]] || { echo "zeeos: $(basename "$f") is not in the lock" >&2; bad=1; }
  done
  return "$bad"
}

# Lock body without the header, for semantic comparison (the timestamp must not count).
pin_lock_body() { grep -v '^#' "$1" | LC_ALL=C sort; }

# Value of a "# key=value" header line.
pin_lock_header() { sed -n "s/^# $2=//p" "$1" | head -1; }

# True when the lock has at least one package line.
pin_lock_resolved() { [[ -n "$(pin_lock_identities "$1")" ]]; }

# rpm file name for an identity ("name epoch:version-release.arch").
pin_rpm_file() {
  local n="$1" vr="${2#*:}"   # the epoch is not part of the file name
  echo "$n-${vr%.*}.${vr##*.}.rpm"
}

# Import Fedora's release keys into a throwaway rpm db and check every RPM in $2... against it.
pin_check_signatures() {
  local db keys=(/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-44-*)
  [[ -e "${keys[0]}" ]] || { echo "Fedora 44 GPG keys missing (fedora-gpg-keys)" >&2; return 1; }
  db="$(mktemp -d)"
  rpmkeys --dbpath "$db" --import "${keys[@]}"
  local out; out="$(rpmkeys --dbpath "$db" --checksig "$@" 2>&1)" || { echo "$out" >&2; rm -rf "$db"; return 1; }
  # rpmkeys exits 0 with "digests OK" (no signature) for unsigned files: require a signature.
  if grep -qv 'signatures OK' <<<"$out"; then echo "$out" | grep -v 'signatures OK' >&2; rm -rf "$db"; return 1; fi
  rm -rf "$db"
}
