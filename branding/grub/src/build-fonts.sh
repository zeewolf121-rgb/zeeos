#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 ZeeOS contributors
# SPDX-License-Identifier: GPL-3.0-or-later
# Run with Fedora's grub2-mkfont (grub2-tools-extra), from any directory.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/fonts"
for size in 16 20 32; do
  grub2-mkfont --size="$size" --range=0x20-0x7e \
    --output="$root/fonts/noto-sans-$size.pf2" "$root/src/NotoSans-Regular.ttf"
  cp "$root/src/NotoSans-Regular.ttf.license" "$root/fonts/noto-sans-$size.pf2.license"
done
