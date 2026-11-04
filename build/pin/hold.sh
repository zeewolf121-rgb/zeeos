#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Hold mode for `make pin-packages HOLD=1` (#310): stage the CURRENT lock's closure repo and a copy of the
# lock in out/<arch>/ so resolve.sh keeps every locked version and only adds new packages.
# Runs on the host (needs podman, like pull.sh). Usage: build/pin/hold.sh <arch>
set -euo pipefail
arch="${1:?usage: hold.sh <arch>}"
# shellcheck source=build/pin/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
out="$PIN_ROOT/out/$arch"
mkdir -p "$out"
rm -rf "$out/held" "$out/held.lock" "$out/zeeos" "$out/zeeos.lock"
"$PIN_ROOT/build/pin/pull.sh" "$arch" "$out/held"
cp "$(pin_lock "$arch")" "$out/held.lock"
echo "hold mode: holding $(pin_lock_identities "$out/held.lock" | wc -l) locked packages for $arch"
