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
    SECUREBOOT=${REPLAY_SB:-off} SCREENSHOT_DELAY=0 TIMEOUT=20 THEME_TIMEOUT=6 vm/boot-test.sh >"$o.log" 2>&1 || rc=$?
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

# Phase-5 marker protocol: ZEEOS_SECUREBOOT and ZEEOS_HARDENING_*. No announce = nothing new is checked.
replay serial-hardening-ok.log pass 'hardening" value="ok"' 'secureboot_guest" value="off"' 'tests="2"' 'failures="0"' \
  'name="boot.x86_64.sb-off.hardening"'
replay serial-hardening-no-announce.log pass 'hardening" value="none"' 'secureboot_guest" value="off"' 'tests="1"'
if grep -q '\.hardening"' "$tmp/out-serial-hardening-no-announce/junit.xml"; then
  echo "FAIL: no-announce run has a hardening testcase" >&2; exit 1; fi
replay serial-plain.log pass 'hardening" value="none"' 'secureboot_guest" value="unreported"'
replay serial-hardening-fail.log fail 'hardening" value="fail"' 'hardening-fail' 'firewall: inbound ssh is open'
replay serial-hardening-missing.log fail 'hardening" value="timeout"' 'hardening-timeout' 'no ZEEOS_HARDENING_OK'
replay serial-hardening-sb-mismatch.log fail 'secureboot-marker-on' 'secureboot_guest" value="on"'
REPLAY_SB=on replay serial-hardening-sb-on-mismatch.log fail 'secureboot-marker-off' 'secureboot_guest" value="off"'

# Real baselines present: a copy of the harness with a full-size baseline at the default location.
# An unisolated fixture run (1x1 shots) must hit the gate; the isolated runs above must not.
mkdir -p "$tmp/repo/build/arch/x86_64/baselines"
cp -r vm tests "$tmp/repo/"
python3 -I -c 'import sys; open(sys.argv[1], "wb").write(b"P6\n1280 800\n255\n" + bytes([60]) * (1280 * 800 * 3))' \
  "$tmp/repo/build/arch/x86_64/baselines/light.ppm"
real=$tmp/out-real; rc=0
(cd "$tmp/repo" && env -u BASELINES FAKE_SERIAL=tests/fixtures/serial-theme-only.log QEMU_BIN="$tmp/qemu" FW_CODE="$fw" FW_VARS="$fw" \
  ISO="$iso" OUT="$real" ARCH=x86_64 SECUREBOOT=off SCREENSHOT_DELAY=0 TIMEOUT=20 THEME_TIMEOUT=6 vm/boot-test.sh) >"$real.log" 2>&1 || rc=$?
{ [ "$rc" != 0 ] && grep -q 'imgdiff-gate' "$real/junit.xml"; } \
  || { echo "FAIL: default baseline gate not applied (exit $rc)" >&2; cat "$real.log" >&2; exit 1; }
REPLAY_BASELINES=$tmp/repo/build/arch/x86_64/baselines replay serial-theme-only.log fail 'imgdiff-gate'
replay serial-plain.log pass 'imgdiff_gate" value="pass"'

# OEM disk boot (vm/oem-boot-test.sh, #277): fixtures are the console lines of real boots of the unpinned oem disk
# (CI run 41631313208, QEMU + AAVMF, HVF), ANSI colour included. The disk is a stand-in file; qemu-img is a shim.
oemdisk=$tmp/oem.raw; : > "$oemdisk"
printf '#!/bin/sh\nfor a; do last=$a; done; : > "$last"\n' > "$tmp/qemu-img"; chmod +x "$tmp/qemu-img"
# oem_replay <fixture> <expect: pass|fail> <SECUREBOOT on|off> <MIN_COLORS> <junit pattern> [junit pattern...]
oem_replay() {
  local fx=$1 want=$2 sb=$3 minc=$4 o rc=0; shift 4
  o=$tmp/oem-${fx%.log}-$sb
  FAKE_SERIAL=tests/fixtures/$fx QEMU_BIN=$tmp/qemu QEMU_IMG=$tmp/qemu-img FW_CODE=$fw FW_VARS=$fw DISK=$oemdisk OUT=$o \
    SECUREBOOT=$sb SETTLE=0 TIMEOUT=6 MIN_COLORS=$minc vm/oem-boot-test.sh >"$o.log" 2>&1 || rc=$?
  if { [ "$want" = pass ] && [ "$rc" != 0 ]; } || { [ "$want" = fail ] && [ "$rc" = 0 ]; }; then
    echo "FAIL: $fx (sb-$sb) expected $want, exit $rc" >&2; cat "$o.log" >&2; exit 1
  fi
  for pat in "$@"; do
    grep -q -- "$pat" "$o/junit.xml" || { echo "FAIL: $fx: junit lacks '$pat'" >&2; cat "$o/junit.xml" >&2; exit 1; }
  done
}
oem_replay serial-oem-ok.log pass off 0 'failures="0"' 'secureboot_kernel" value="disabled"' 'missing_markers" value="none"'
oem_replay serial-oem-sb-on.log pass on 0 'failures="0"' 'secureboot_kernel" value="enabled"'
# Secure Boot state that differs from the request fails the cell, in both directions.
oem_replay serial-oem-ok.log fail on 0 'secureboot-disabled'
oem_replay serial-oem-sb-on.log fail off 0 'secureboot-enabled'
# A missing first-boot marker fails and is named; so does a systemd [FAILED] line.
oem_replay serial-oem-no-sddm.log fail off 0 'missing_markers" value="sddm"' 'missing: sddm'
oem_replay serial-oem-no-session.log fail off 0 'missing_markers" value="wizard-session"'
oem_replay serial-oem-failed.log fail off 0 'boot_failed' 'FAILED'
# The wizard session ends (real audit lines of the unpinned disk: core dumps, then user@992 stops): fails.
oem_replay serial-oem-wizard-died.log fail off 0 'wizard_session_ended' 'type=1701'
oem_replay serial-oem-user-stopped.log fail off 0 'wizard_session_ended' 'unit=user@992'
# Graphical gate: off by default; with MIN_COLORS the 1-colour fixture screenshot fails it.
oem_replay serial-oem-ok.log pass off 0 'screenshot_colors" value="1"'
oem_replay serial-oem-ok.log fail off 50 'screenshot-colors-1-below-50'
if ARCH=x86_64 DRY_RUN=1 OUT=$tmp vm/oem-boot-test.sh 2>/dev/null; then echo "FAIL: oem test accepted ARCH=x86_64" >&2; exit 1; fi
oemout=$(DRY_RUN=1 OUT=$tmp DISK=$oemdisk SECUREBOOT=off vm/oem-boot-test.sh)
grep -q 'qemu-system-aarch64' <<<"$oemout" || { echo "FAIL: oem dry run prints no qemu command" >&2; exit 1; }
if grep -q 'media=cdrom' <<<"$oemout"; then echo "FAIL: oem run attached an ISO" >&2; exit 1; fi
[ ! -s "$oemdisk" ] || { echo "FAIL: oem disk was written" >&2; exit 1; }

rm -rf "$tmp"
bash tests/imgdiff_gate_test.sh
bash tests/install-selftest.sh
echo "selftest ok"
