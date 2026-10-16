#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline checks of vm/boot-test.sh: no QEMU needed.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
out=$(DRY_RUN=1 OUT=$tmp ARCH=x86_64 SECUREBOOT=off vm/boot-test.sh)
grep -q 'qemu-system-x86_64' <<<"$out" || { echo "FAIL: no qemu command" >&2; exit 1; }
if SECUREBOOT=maybe DRY_RUN=1 OUT=$tmp vm/boot-test.sh 2>/dev/null; then echo "FAIL: bad SECUREBOOT accepted" >&2; exit 1; fi
if ARCH=riscv DRY_RUN=1 OUT=$tmp vm/boot-test.sh 2>/dev/null; then echo "FAIL: bad ARCH accepted" >&2; exit 1; fi
rm -rf "$tmp"
echo "selftest ok"
