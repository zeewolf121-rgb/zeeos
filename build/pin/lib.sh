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

# Identities of a lock file (sha256 and source columns dropped).
pin_lock_identities() { grep -v '^#' "$1" | awk 'NF >= 3 { print $1, $2 }' | LC_ALL=C sort -u; }

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
