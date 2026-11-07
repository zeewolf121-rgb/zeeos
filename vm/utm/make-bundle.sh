#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the UTM bundle from the raw oem disk (P5-5): raw -> compressed qcow2 -> zeeos-<ver>-aarch64.utm -> .utm.zip.
# Env: DISK=<raw oem image, required unless DRY_RUN=1>  VERSION=<ver, default 0.0.0-dev>  OUT=<dir, default out/utm>
#      CPUS=4 MEMORY=4096 (MiB)  QEMU_IMG=<qemu-img>  DRY_RUN=1 (print the steps, touch nothing)
# Result: OUT/zeeos-<ver>-aarch64.utm (config.plist and Data/zeeos-<ver>-aarch64.qcow2) and OUT/zeeos-<ver>-aarch64.utm.zip.
# The zip is a file because a release asset cannot be a directory (docs/phases/phase-5.md). Nothing here writes to a disk
# device; the input image is only read.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION=${VERSION:-0.0.0-dev}; OUT=${OUT:-out/utm}; DISK=${DISK:-}; DRY_RUN=${DRY_RUN:-0}
CPUS=${CPUS:-4}; MEMORY=${MEMORY:-4096}; qimg=${QEMU_IMG:-qemu-img}
case $VERSION in *[!A-Za-z0-9._+-]*|"") echo "bad VERSION '$VERSION'" >&2; exit 2;; esac
case $CPUS$MEMORY in *[!0-9]*) echo "CPUS and MEMORY must be numbers" >&2; exit 2;; esac
name=zeeos-$VERSION-aarch64
bundle=$OUT/$name.utm; image=$name.qcow2; zip=$OUT/$name.utm.zip
run() { if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi; }
if [ "$DRY_RUN" != 1 ]; then
  [ -n "$DISK" ] && [ -r "$DISK" ] || { echo "oem disk not found; set DISK=<raw image>" >&2; exit 2; }
  command -v "$qimg" >/dev/null || [ -x "$qimg" ] || { echo "$qimg not installed" >&2; exit 2; }
else echo "dry run: nothing is written (input ${DISK:-DISK-unset})"; fi
run rm -rf "$bundle" "$zip"
run mkdir -p "$bundle/Data"
run "$qimg" convert -c -f raw -O qcow2 "${DISK:-DISK-unset}" "$bundle/Data/$image"
run python3 -I "$here/utm-config.py" render "$here/config.plist.in" "$bundle/config.plist" "$name" "$image" --cpus "$CPUS" --memory "$MEMORY"
run python3 -I "$here/utm-config.py" zip "$bundle" "$zip"
[ "$DRY_RUN" = 1 ] || echo "bundle: $bundle ($(wc -c < "$zip") byte zip $zip)"
