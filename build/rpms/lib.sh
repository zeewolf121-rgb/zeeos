#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Helpers for the ZeeOS RPM rebuild pipeline (ADR-0011). Source this file; do not run it.
# shellcheck source=build/pin/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../pin/lib.sh"

RPMS_DIR="$PIN_ROOT/build/rpms"

# Load build/rpms/<name>/source.lock into NAME, SRPM, SRPM_SHA256, RPMBUILD_OPTS.
rpms_load_source() {
  local f="$RPMS_DIR/$1/source.lock"
  [[ -f "$f" ]] || { echo "no $f" >&2; return 1; }
  # shellcheck disable=SC2034  # read by build.sh and lock-source.sh
  NAME='' SRPM='' SRPM_SHA256='' RPMBUILD_OPTS=''
  # Plain KEY=value lines only; never sourced as shell.
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      NAME|SRPM|SRPM_SHA256|RPMBUILD_OPTS) printf -v "$k" '%s' "$v" ;;
    esac
  done < <(grep -E '^[A-Z_0-9]+=' "$f")
  [[ "$NAME" == "$1" ]] || { echo "$f: NAME=$NAME, expected $1" >&2; return 1; }
  [[ "$SRPM" =~ ^[A-Za-z0-9._+-]+\.src\.rpm$ ]] || { echo "$f: bad SRPM name '$SRPM'" >&2; return 1; }
}

# Download $SRPM into <dir>/$SRPM from the Fedora mirrors, then Koji's signed copy.
# Prints the sha256 of the file it kept. Verification against the lock is the caller's job.
rpms_download_srpm() {
  local dir="$1" mirror koji keyid l vrn ver rel
  mirror="${ZEEOS_MIRROR_URL:-https://dl.fedoraproject.org/pub/fedora/linux}"
  koji="${ZEEOS_KOJI_URL:-https://kojipkgs.fedoraproject.org/packages}"
  keyid="${ZEEOS_KOJI_KEYID:-6d9f90a6}"
  l="${SRPM:0:1}"; l="${l,,}"
  vrn="${SRPM%.src.rpm}"; rel="${vrn##*-}"; ver="${vrn%-*}"; ver="${ver##*-}"
  mkdir -p "$dir"
  local u
  for u in "$mirror/updates/44/Everything/source/tree/Packages/$l/$SRPM" \
           "$mirror/releases/44/Everything/source/tree/Packages/$l/$SRPM" \
           "$koji/$NAME/$ver/$rel/data/signed/$keyid/src/$SRPM"; do
    if curl -fsSL --retry 3 -o "$dir/$SRPM.part" "$u"; then
      mv "$dir/$SRPM.part" "$dir/$SRPM"
      sha256sum "$dir/$SRPM" | cut -d' ' -f1
      return 0
    fi
    rm -f "$dir/$SRPM.part"
  done
  echo "cannot fetch $SRPM from the mirrors or Koji" >&2
  return 1
}
