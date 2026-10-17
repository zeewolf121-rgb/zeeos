#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Boot a ZeeOS ISO under QEMU + OVMF/AAVMF and wait for the desktop-ready serial marker.
# Env: ARCH=x86_64|aarch64  SECUREBOOT=on|off  ISO=<path>  DISK=<seed image, optional>
#      OUT=<result dir>  TIMEOUT=<seconds>  MARKER=<serial string>  DRY_RUN=1 (print command only)
#      SCREENSHOT_DELAY=<seconds after the marker; default 0, 90 under TCG>
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

: > "$OUT/serial.log"
"$qemu" "${args[@]}" 2>"$OUT/qemu.stderr" &
qpid=$!
trap 'kill "$qpid" 2>/dev/null || true' EXIT
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
  [ "$result" = pass ] && sleep "$shot_delay"
  # The guest may have crashed or rebooted during the delay: recheck, and fail without a screenshot.
  if ! kill -0 "$qpid" 2>/dev/null; then
    [ "$result" != pass ] || result=qemu-exited-before-screenshot
  elif ! python3 -I "$here/qmp.py" "$sock" screendump "{\"filename\":\"$PWD/$OUT/screenshot.ppm\"}" >/dev/null; then
    echo "screendump failed" >&2
    [ "$result" != pass ] || result=screendump-failed
  fi
  python3 -I "$here/qmp.py" "$sock" quit >/dev/null 2>&1 || true
fi

# The guest kernel must report the Secure Boot state that was asked for, or the cell proves nothing.
want=enabled; [ "$SECUREBOOT" = off ] && want=disabled
got=$(grep -aom1 'secureboot: Secure boot [a-z]*' "$OUT/serial.log" | awk '{print $NF}' || true)
if [ "$got" != "$want" ]; then result="$result,secureboot-${got:-unreported}"; fi

name="boot.$ARCH.sb-$SECUREBOOT"
fail=1; [ "$result" = pass ] && fail=0
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  printf '<testsuite name="zeeos-boot" tests="1" failures="%d" time="%d">\n' "$fail" "$elapsed"
  printf '<properties><property name="accel" value="%s"/><property name="arch" value="%s"/><property name="secureboot" value="%s"/></properties>\n' "$accel" "$ARCH" "$SECUREBOOT"
  printf '<testcase classname="boot" name="%s" time="%d">' "$name" "$elapsed"
  [ "$fail" = 0 ] || printf '<failure message="marker %s: %s"/>' "$MARKER" "$result"
  echo '</testcase></testsuite>'
} > "$OUT/junit.xml"
echo "$name: $result after ${elapsed}s (accel=$accel); results in $OUT"
exit "$fail"
