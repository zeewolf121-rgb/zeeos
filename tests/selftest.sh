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

# Marker protocol (docs/phases/phase-3.md): replay fixture serial logs through the harness with a fake QEMU.
# Fixture runs emit 1x1 screenshots, so they must never be compared with the repository's real
# build/arch/<arch>/baselines: point the gate at an explicit empty temp directory instead.
mkdir "$tmp/no-baselines"
fw=$tmp/fw; : > "$fw"; iso=$tmp/fake.iso; : > "$iso"
printf '#!/bin/sh\nexec python3 -I "%s" "$@"\n' "$PWD/tests/fake-qemu.py" > "$tmp/qemu"; chmod +x "$tmp/qemu"
# replay <fixture> <expect: pass|fail> <junit pattern> [junit pattern...]
replay() {
  local fx=$1 want=$2 o rc=0; shift 2
  o=$tmp/out-${fx%.log}
  BASELINES=${REPLAY_BASELINES:-$tmp/no-baselines} FAKE_SERIAL=tests/fixtures/$fx QEMU_BIN=$tmp/qemu FW_CODE=$fw FW_VARS=$fw ISO=$iso OUT=$o ARCH=x86_64 \
    SECUREBOOT=off SCREENSHOT_DELAY=0 TIMEOUT=20 THEME_TIMEOUT=6 vm/boot-test.sh >"$o.log" 2>&1 || rc=$?
  if { [ "$want" = pass ] && [ "$rc" != 0 ]; } || { [ "$want" = fail ] && [ "$rc" = 0 ]; }; then
    echo "FAIL: $fx expected $want, exit $rc" >&2; cat "$o.log" >&2; exit 1
  fi
  for pat in "$@"; do
    grep -q -- "$pat" "$o/junit.xml" || { echo "FAIL: $fx: junit lacks '$pat'" >&2; cat "$o/junit.xml" >&2; exit 1; }
  done
}
# No announce: behaves as before (no layout markers required, no step results).
replay serial-plain.log pass 'tests="1"' 'layout_check" value="none"'
replay serial-theme-only.log pass 'layout_check" value="none"' 'name="boot.x86_64.sb-off.dark"'
replay serial-layout-ok.log pass 'layout_check" value="ok"' 'tests="6"' 'failures="0"'
for m in windows mac hybrid; do
  [ -s "$tmp/out-serial-layout-ok/screenshot-$m.ppm" ] || { echo "FAIL: no screenshot-$m.ppm" >&2; exit 1; }
done
# Announced but a marker never arrives: the cell fails and names the step.
replay serial-layout-no-hybrid.log fail 'timeout-hybrid' 'name="boot.x86_64.sb-off.hybrid"'
replay serial-layout-fail.log fail 'layout-fail-mac' '<skipped/>'
# PID 1 froze in early boot: the harness boots once more; a second freeze ends in a timeout.
replay serial-freeze.log fail 'boot_retry" value="1"' 'marker ZEEOS_DESKTOP_READY: timeout'
[ -s "$tmp/out-serial-freeze/serial-attempt1.log" ] || { echo "FAIL: no serial-attempt1.log" >&2; exit 1; }

# Real baselines present: a copy of the harness with a full-size baseline at the default location.
# An unisolated fixture run (1x1 shots) must hit the gate; the isolated runs above must not.
mkdir -p "$tmp/repo/build/arch/x86_64/baselines"
cp -r vm tests "$tmp/repo/"
python3 -I -c 'import sys; open(sys.argv[1], "wb").write(b"P6\n1280 800\n255\n" + bytes([60]) * (1280 * 800 * 3))' \
  "$tmp/repo/build/arch/x86_64/baselines/light.ppm"
real=$tmp/out-real; rc=0
(cd "$tmp/repo" && env -u BASELINES FAKE_SERIAL=tests/fixtures/serial-plain.log QEMU_BIN="$tmp/qemu" FW_CODE="$fw" FW_VARS="$fw" \
  ISO="$iso" OUT="$real" ARCH=x86_64 SECUREBOOT=off SCREENSHOT_DELAY=0 TIMEOUT=20 THEME_TIMEOUT=6 vm/boot-test.sh) >"$real.log" 2>&1 || rc=$?
{ [ "$rc" != 0 ] && grep -q 'imgdiff-gate' "$real/junit.xml"; } \
  || { echo "FAIL: default baseline gate not applied (exit $rc)" >&2; cat "$real.log" >&2; exit 1; }
REPLAY_BASELINES=$tmp/repo/build/arch/x86_64/baselines replay serial-plain.log fail 'imgdiff-gate'
replay serial-plain.log pass 'imgdiff_gate" value="pass"'

rm -rf "$tmp"
bash tests/imgdiff_gate_test.sh
bash tests/install-selftest.sh
echo "selftest ok"
