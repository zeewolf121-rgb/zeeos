#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Put the locked closure repo into <dir> by pulling its OCI image by digest (ADR-0008).
# Anonymous when the package is public; otherwise `podman login ghcr.io` (read:packages) first.
# Never falls back to live repos. Usage: build/pin/pull.sh <arch> <dir>
set -euo pipefail
arch="${1:?usage: pull.sh <arch> <dir>}"
dir="${2:?usage: pull.sh <arch> <dir>}"
# shellcheck source=build/pin/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
lock="$(pin_lock "$arch")"
pin_lock_resolved "$lock" || { echo "$lock has no packages yet: run 'make pin-packages ARCH=$arch' (or set ZEEOS_UNPINNED=1 for an unpinned developer build)" >&2; exit 1; }
ref="$(pin_lock_header "$lock" closure)"
[[ "$ref" == *@sha256:* ]] || { echo "$lock names no closure image digest: run 'make pin-packages ARCH=$arch'" >&2; exit 1; }
engine="$(command -v podman || command -v docker)" || { echo "need podman or docker" >&2; exit 2; }
rm -rf "$dir"; mkdir -p "$dir"
if "$engine" pull -q "$ref" >/dev/null 2>&1; then
  cid="$("$engine" create "$ref" /repo)"
  "$engine" cp "$cid:/repo/." "$dir"
  "$engine" rm "$cid" >/dev/null
  echo "pulled closure repo $ref"
  exit 0
fi
cat >&2 <<EOF
cannot pull $ref. Access paths (ADR-0008):
  1. the owner makes the GHCR package public (one-time step per package);
  2. 'echo \$(gh auth token) | $engine login ghcr.io -u <user> --password-stdin' (token needs read:packages);
  3. rebuild from the lock: ZEEOS_CLOSURE_REBUILD=1 make iso ARCH=$arch (hashes are checked, but
     superseded RPMs may be gone from mirrors and Koji).
EOF
exit 1
