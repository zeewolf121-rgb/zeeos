#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Record SRPM_SHA256 in build/rpms/<name>/source.lock from a real download (ADR-0011). The file must
# carry a Fedora signature; the hash is only written after that check passes. A reviewer then checks
# the new hash against Koji's build page. Runs in the build container (needs curl, rpm, Fedora keys).
# Usage: build/rpms/lock-source.sh <arch>   with ZEEOS_RPMS_ONLY=<name>
set -euo pipefail
# shellcheck source=build/rpms/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
name="${ZEEOS_RPMS_ONLY:?set ZEEOS_RPMS_ONLY=<package name>}"
rpms_load_source "$name"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sha="$(rpms_download_srpm "$tmp")"
pin_check_signatures "$tmp/$SRPM"
if [[ -n "$SRPM_SHA256" && "$SRPM_SHA256" != "$sha" ]]; then
  echo "$SRPM is already locked to $SRPM_SHA256 but the download hashes to $sha: refusing to overwrite" >&2
  exit 1
fi
sed -i "s|^SRPM_SHA256=.*|SRPM_SHA256=$sha|" "$RPMS_DIR/$name/source.lock"
echo "locked $SRPM sha256 $sha (Fedora signature verified)"
