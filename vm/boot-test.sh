#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Boot a ZeeOS ISO under QEMU + OVMF/AAVMF and wait for the desktop-ready serial marker.
# Env: ARCH=x86_64|aarch64  SECUREBOOT=on|off  ISO=<path>  DISK=<seed image, optional>
#      OUT=<result dir>  TIMEOUT=<seconds>  MARKER=<serial string>  DRY_RUN=1 (print command only)
#      SCREENSHOT_DELAY=<seconds after the marker; default 0, 90 under TCG>
#      QEMU_BIN / FW_CODE / FW_VARS override the emulator and firmware (offline tests/selftest.sh)
# Writes OUT/{serial.log,screenshot.ppm,junit.xml,accel}. DISK is attached through a qcow2
# overlay, so the seed image is never modified.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ARCH=${ARCH:-x86_64}; SECUREBOOT=${SECUREBOOT:-on}; TIMEOUT=${TIMEOUT:-600}
MARKER=${MARKER:-ZEEOS_DESKTOP_READY}; OUT=${OUT:-out/boot-test/$ARCH-sb$SECUREBOOT}
DRY_RUN=${DRY_RUN:-0}; DISK=${DISK:-}
ISO=${ISO:-$(ls -t out/*"$ARCH"*.iso build/out/*"$ARCH"*.iso 2>/dev/null | head -1 || true)}
case $SECUREBOOT in on|off) ;; *) echo "SECUREBOOT must be on|off" >&2; exit 2;; esac

first() { for f in "$@"; do [ -r "$f" ] && { echo "$f"; return 0; }; done; return 1; }

case $ARCH in
  x86_64)
    qemu=qemu-system-x86_64
    machine=(-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on)
    cpu=max
    if [ "$SECUREBOOT" = on ]; then
      code=$(first /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd /usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
        /usr/share/OVMF/OVMF_CODE.secboot.fd || true)
      # Microsoft-keys enrolled vars
      vars=$(first /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd /usr/share/OVMF/OVMF_VARS_4M.ms.fd \
        /usr/share/OVMF/OVMF_VARS.secboot.fd || true)
    else
      code=$(first /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd || true)
      vars=$(first /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd || true)
    fi ;;
  aarch64)
    qemu=qemu-system-aarch64; machine=(-machine virt,gic-version=max); cpu=max
    if [ "$SECUREBOOT" = on ]; then
      # SB needs a secboot-built CODE plus MS-keys VARS (Debian/Ubuntu AAVMF); plain AAVMF_CODE.fd
      # boots with "Secure boot disabled" even with .ms VARS. No silent fallback to non-SB.
      code=$(first /usr/share/AAVMF/AAVMF_CODE.ms.fd /usr/share/AAVMF/AAVMF_CODE.secboot.fd || true)
      vars=$(first /usr/share/AAVMF/AAVMF_VARS.ms.fd || true)
    else
      code=$(first /usr/share/edk2/aarch64/QEMU_EFI-silent-pflash.raw /usr/share/AAVMF/AAVMF_CODE.no-secboot.fd \
        /usr/share/AAVMF/AAVMF_CODE.fd || true)
      vars=$(first /usr/share/edk2/aarch64/vars-template-pflash.raw /usr/share/AAVMF/AAVMF_VARS.fd || true)
    fi ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2;;
esac
qemu=${QEMU_BIN:-$qemu}; code=${FW_CODE:-${code:-}}; vars=${FW_VARS:-${vars:-}}

if [ "$DRY_RUN" != 1 ]; then
  command -v "$qemu" >/dev/null || { echo "$qemu not installed" >&2; exit 2; }
  [ -n "${code:-}" ] && [ -n "${vars:-}" ] || { echo "no $ARCH firmware (SB=$SECUREBOOT) found" >&2; exit 2; }
  [ -n "$ISO" ] && [ -r "$ISO" ] || { echo "ISO not found; set ISO=<path>" >&2; exit 2; }
fi

accel=tcg
if [ -w /dev/kvm ] && [ "$ARCH" = "$(uname -m)" ]; then accel=kvm; cpu=host
elif [ "$(uname -s)" = Darwin ] && [ "$ARCH" = "$(uname -m | sed s/arm64/aarch64/)" ]; then accel=hvf; cpu=host; fi

# aarch64 under TCG is slow enough that systemd's generators time out (~90 s). Cheap pointer-auth
# emulation and multi-threaded TCG cut boot time substantially.
smp=2
if [ "$accel" = tcg ] && [ "$ARCH" = aarch64 ]; then cpu=max,pauth-impdef=on; smp=4; fi

mkdir -p "$OUT"
echo "$accel" > "$OUT/accel"
[ -n "${vars:-}" ] && cp "$vars" "$OUT/vars.fd"
sock=$OUT/qmp.sock
args=(-accel "$accel" -cpu "$cpu" -m 4096 -smp "$smp" "${machine[@]}"
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=${code:-/nonexistent}"
  -drive "if=pflash,format=raw,unit=1,file=$OUT/vars.fd"
  -drive "file=${ISO:-/nonexistent},media=cdrom,readonly=on"
  -device virtio-gpu-pci -device qemu-xhci -device usb-kbd
  -serial "file:$OUT/serial.log" -display none -qmp "unix:$sock,server=on,wait=off" -no-reboot)
if [ -n "$DISK" ]; then
  [ "$DRY_RUN" = 1 ] || qemu-img create -q -f qcow2 -b "$(realpath "$DISK")" -F raw "$OUT/seed-overlay.qcow2"
  args+=(-drive "file=$OUT/seed-overlay.qcow2,if=virtio,format=qcow2")
fi
if [ "$DRY_RUN" = 1 ]; then echo "$qemu ${args[*]}"; exit 0; fi

# Per-run artifacts: a reused OUT must not leak an earlier run's screenshots into this diff/report.
rm -f "$OUT"/screenshot*.ppm
: > "$OUT/serial.log"
"$qemu" "${args[@]}" 2>"$OUT/qemu.stderr" &
qpid=$!
trap 'kill "$qpid" 2>/dev/null || true' EXIT
# QEMU resolves the filename against its own cwd: pass it absolute, without doubling an absolute OUT.
shot() {
  local f=$1; [ "${f#/}" != "$f" ] || f=$PWD/$f
  python3 -I "$here/qmp.py" "$sock" screendump "{\"filename\":\"$f\"}" >/dev/null
}
# Wait up to $2 s for a serial line matching $1. 0 = found, 1 = a ZEEOS_*_FAIL line seen, 2 = timeout/QEMU gone.
wait_for() {
  local t=$SECONDS
  while (( SECONDS - t < $2 )); do
    grep -aq -- "$1" "$OUT/serial.log" && return 0
    grep -aq -e '^ZEEOS_THEME_FAIL' -e '^ZEEOS_LAYOUT_FAIL' -e '^ZEEOS_RTL_FAIL' "$OUT/serial.log" && return 1
    kill -0 "$qpid" 2>/dev/null || return 2
    sleep 2
  done
  return 2
}
theme=none; layout=none; steps=(); declare -A stepres=()
start=$SECONDS; result=timeout
while (( SECONDS - start < TIMEOUT )); do
  if grep -aq -- "$MARKER" "$OUT/serial.log"; then result=pass; break; fi
  kill -0 "$qpid" 2>/dev/null || { result=qemu-exited; break; }
  sleep 2
done
elapsed=$((SECONDS - start))

if kill -0 "$qpid" 2>/dev/null; then
  # Under TCG, Plasma's software rendering needs well over a minute to paint after the marker;
  # an immediate screendump is black (aarch64, run 39021393078). Only delay on a pass.
  shot_delay=${SCREENSHOT_DELAY:-0}; [ "$accel" = tcg ] && shot_delay=${SCREENSHOT_DELAY:-90}
  # With the theme or layout check, the per-marker delays below replace this one: sleeping here too would
  # eat into the guest's light-mode window, and the "light" screenshot would show dark mode.
  has_theme=0; grep -aq '^ZEEOS_THEME_CHECK' "$OUT/serial.log" && has_theme=1
  has_layout=0; grep -aq '^ZEEOS_LAYOUT_CHECK' "$OUT/serial.log" && has_layout=1
  [ "$result" = pass ] && [ "$has_theme" = 0 ] && [ "$has_layout" = 0 ] && sleep "$shot_delay"
  # The guest may have crashed or rebooted during the delay: recheck, and fail without a screenshot.
  if ! kill -0 "$qpid" 2>/dev/null; then
    [ "$result" != pass ] || result=qemu-exited-before-screenshot
  elif ! shot "$OUT/screenshot.ppm"; then
    echo "screendump failed" >&2
    [ "$result" != pass ] || result=screendump-failed
  elif [ "$result" = pass ] && { [ "$has_theme" = 1 ] || [ "$has_layout" = 1 ]; }; then
    # Phase-2 theme check: light and dark markers. Phase-3 layout check: one per mode, then RTL.
    # Each step is "<grep pattern>|<name>"; its screenshot is screenshot-<name>.ppm.
    [ "$has_theme" = 0 ] || { theme=ok; steps+=("ZEEOS_THEME_OK|light" "ZEEOS_DARK_READY|dark"); }
    [ "$has_layout" = 0 ] || { layout=ok; steps+=("ZEEOS_LAYOUT_OK mode=windows|windows" "ZEEOS_LAYOUT_OK mode=mac|mac" \
      "ZEEOS_LAYOUT_OK mode=hybrid|hybrid" "ZEEOS_RTL_OK|rtl"); }
    failed=""
    for step in "${steps[@]}"; do
      pat=${step%|*}; nm=${step#*|}
      if [ -n "$failed" ]; then stepres[$nm]=skipped; continue; fi
      kind=theme; case $nm in windows|mac|hybrid|rtl) kind=layout;; esac
      st=; rc=0
      wait_for "^$pat" "${THEME_TIMEOUT:-600}" || rc=$?
      if [ "$rc" = 1 ]; then st=fail; elif [ "$rc" != 0 ]; then st=timeout; fi
      if [ -z "$st" ]; then
        sleep "$shot_delay"
        if ! kill -0 "$qpid" 2>/dev/null || ! shot "$OUT/screenshot-$nm.ppm"; then st=screenshot; fi
      fi
      if [ -n "$st" ]; then
        stepres[$nm]=$st; failed=$kind-$st-$nm
        if [ "$kind" = theme ]; then theme=$st-$nm; else layout=$st-$nm; fi
      else
        stepres[$nm]=ok
      fi
    done
    [ -z "$failed" ] || result=$failed
    # screenshot.ppm was taken before the desktop painted; the light capture is the real one.
    [ ! -s "$OUT/screenshot-light.ppm" ] || cp "$OUT/screenshot-light.ppm" "$OUT/screenshot.ppm"
  fi
  python3 -I "$here/qmp.py" "$sock" quit >/dev/null 2>&1 || true
fi

mem=$(grep -aom1 '^ZEEOS_MEM .*' "$OUT/serial.log" || true)
memkv() { echo "$mem" | grep -o "$1=[0-9]*" | cut -d= -f2 || true; }
diffpct=""
if [ -s "$OUT/screenshot-light.ppm" ] && [ -s "$OUT/screenshot-dark.ppm" ]; then
  # Report-only: never affects the result.
  diffpct=$(python3 -I "$here/imgdiff.py" "$OUT/screenshot-light.ppm" "$OUT/screenshot-dark.ppm" || true)
fi

# The guest kernel must report the Secure Boot state that was asked for, or the cell proves nothing.
want=enabled; [ "$SECUREBOOT" = off ] && want=disabled
got=$(grep -aom1 'secureboot: Secure boot [a-z]*' "$OUT/serial.log" | awk '{print $NF}' || true)
if [ "$got" != "$want" ]; then result="$result,secureboot-${got:-unreported}"; fi

name="boot.$ARCH.sb-$SECUREBOOT"
fail=1; [ "$result" = pass ] && fail=0
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  # One extra testcase per theme/layout step; a failed step counts as a failure of its own.
  nfail=$fail; for nm in "${!stepres[@]}"; do [ "${stepres[$nm]}" = ok ] || [ "${stepres[$nm]}" = skipped ] || nfail=$((nfail + 1)); done
  printf '<testsuite name="zeeos-boot" tests="%d" failures="%d" time="%d">\n' "$((1 + ${#steps[@]}))" "$nfail" "$elapsed"
  printf '<properties><property name="accel" value="%s"/><property name="arch" value="%s"/><property name="secureboot" value="%s"/>' "$accel" "$ARCH" "$SECUREBOOT"
  printf '<property name="theme_check" value="%s"/><property name="boot_seconds" value="%d"/>' "$theme" "$elapsed"
  printf '<property name="layout_check" value="%s"/>' "$layout"
  for k in total_kb available_kb used_kb; do
    v=$(memkv "$k"); [ -z "$v" ] || printf '<property name="idle_%s" value="%s"/>' "$k" "$v"
  done
  [ -z "$diffpct" ] || printf '<property name="light_dark_diff_pct" value="%s"/>' "$diffpct"
  echo '</properties>'
  printf '<testcase classname="boot" name="%s" time="%d">' "$name" "$elapsed"
  [ "$fail" = 0 ] || printf '<failure message="marker %s: %s"/>' "$MARKER" "$result"
  echo '</testcase>'
  for step in "${steps[@]}"; do
    nm=${step#*|}; r=${stepres[$nm]:-skipped}
    printf '<testcase classname="boot.step" name="%s.%s">' "$name" "$nm"
    case $r in ok) ;; skipped) printf '<skipped/>';; *) printf '<failure message="step %s: %s"/>' "$nm" "$r";; esac
    echo '</testcase>'
  done
  echo '</testsuite>'
} > "$OUT/junit.xml"
echo "$name: $result after ${elapsed}s (accel=$accel); results in $OUT"
exit "$fail"
