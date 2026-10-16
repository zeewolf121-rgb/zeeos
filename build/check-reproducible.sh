#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build twice from the same commit and diff the package lists (artifact: out/<arch>-package-diff.txt).
# Usage: build/check-reproducible.sh <arch>
set -euo pipefail
arch="${1:?usage: check-reproducible.sh <arch>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for n in 1 2; do
  "$root/build/container/run.sh" "$arch" "$root/out/$arch-run$n"
done
diff -u "$root/out/$arch-run1/packages.list" "$root/out/$arch-run2/packages.list" \
  | tee "$root/out/$arch-package-diff.txt"
echo "package lists identical for $arch"
