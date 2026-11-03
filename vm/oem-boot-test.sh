#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Boot the raw oem disk image of the UTM bundle (#277, P5-5) under QEMU + AAVMF and check the first-boot markers.
# Env: DISK=<raw image, required>  SECUREBOOT=on|off  OUT=<result dir>  TIMEOUT=<seconds, default 300; 1800 under TCG>
#      SETTLE=<seconds from the last marker to the screenshot; default 30, 120 under TCG>  DRY_RUN=1 (print command only)
#      MIN_COLORS=<n> fail unless the final screenshot has at least n distinct colours (default 0: report only; a text
#      console has 2, a painted Plasma wizard has hundreds)
#      QEMU_BIN / QEMU_IMG / FW_CODE / FW_VARS override the emulator, qemu-img and firmware (offline tests/selftest.sh)
# The oem disk has no user before the plasma-setup wizard, so ZEEOS_DESKTOP_READY cannot apply: the pass marker is the
# OEM_MARKERS list of vm/markers.sh plus the kernel's Secure Boot state. See vm/README.md.
# Writes OUT/{serial.log,serial.clean.log,screenshot.ppm,junit.xml,accel}. The image is attached through a qcow2
# overlay, so it is never modified. aarch64 only (the oem disk is built for UTM on Apple silicon).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=markers.sh
. "$here/markers.sh"
ARCH=${ARCH:-aarch64}; SECUREBOOT=${SECUREBOOT:-on}; DISK=${DISK:-}
OUT=${OUT:-out/oem-boot-test/$ARCH-sb$SECUREBOOT}; DRY_RUN=${DRY_RUN:-0}
case $SECUREBOOT in on|off) ;; *) echo "SECUREBOOT must be on|off" >&2; exit 2;; esac
[ "$ARCH" = aarch64 ] || { echo "the oem disk is aarch64 only (ARCH=$ARCH)" >&2; exit 2; }

first() { for f in "$@"; do [ -r "$f" ] && { echo "$f"; return 0; }; done; return 1; }
if [ "$SECUREBOOT" = on ]; then
  # Same firmware rules as vm/boot-test.sh: a secboot-built CODE plus MS-keys VARS, never a silent non-SB fallback.
  code=$(first /usr/share/AAVMF/AAVMF_CODE.ms.fd /usr/share/AAVMF/AAVMF_CODE.secboot.fd || true)
  vars=$(first /usr/share/AAVMF/AAVMF_VARS.ms.fd || true)
else
  code=$(first /usr/share/edk2/aarch64/QEMU_EFI-silent-pflash.raw /usr/share/AAVMF/AAVMF_CODE.no-secboot.fd \
    /usr/share/AAVMF/AAVMF_CODE.fd || true)
  vars=$(first /usr/share/edk2/aarch64/vars-template-pflash.raw /usr/share/AAVMF/AAVMF_VARS.fd || true)
fi
qemu=${QEMU_BIN:-qemu-system-aarch64}; code=${FW_CODE:-${code:-}}; vars=${FW_VARS:-${vars:-}}
if [ "$DRY_RUN" != 1 ]; then
  command -v "$qemu" >/dev/null || [ -x "$qemu" ] || { echo "$qemu not installed" >&2; exit 2; }
  [ -n "$code" ] && [ -n "$vars" ] || { echo "no aarch64 firmware (SB=$SECUREBOOT) found" >&2; exit 2; }
  [ -n "$DISK" ] && [ -r "$DISK" ] || { echo "oem disk not found; set DISK=<raw image>" >&2; exit 2; }
fi

accel=tcg; cpu=max; smp=2
if [ -w /dev/kvm ] && [ "$(uname -m)" = aarch64 ]; then accel=kvm; cpu=host
elif [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then accel=hvf; cpu=host; fi
tmo=300; settle=${SETTLE:-30}
if [ "$accel" = tcg ]; then cpu=max,pauth-impdef=on; smp=4; tmo=1800; settle=${SETTLE:-120}; fi
TIMEOUT=${TIMEOUT:-$tmo}

mkdir -p "$OUT"
sock=$OUT/qmp.sock
args=(-accel "$accel" -cpu "$cpu" -m 4096 -smp "$smp" -machine "virt,gic-version=max"
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=${code:-/nonexistent}"
  -drive "if=pflash,format=raw,unit=1,file=$OUT/vars.fd"
  -drive "file=$OUT/oem-overlay.qcow2,if=virtio,format=qcow2"
  -device virtio-gpu-pci -device qemu-xhci -device usb-kbd
  -serial "file:$OUT/serial.log" -display none -qmp "unix:$sock,server=on,wait=off" -no-reboot)
if [ "$DRY_RUN" = 1 ]; then echo "$qemu ${args[*]}"; exit 0; fi

echo "$accel" > "$OUT/accel"
rm -f "$OUT"/screenshot*.ppm "$sock"
"${QEMU_IMG:-qemu-img}" create -q -f qcow2 -b "$(cd "$(dirname "$DISK")" && pwd)/$(basename "$DISK")" -F raw "$OUT/oem-overlay.qcow2"
cp "$vars" "$OUT/vars.fd"; : > "$OUT/serial.log"
"$qemu" "${args[@]}" 2>"$OUT/qemu.stderr" &
qpid=$!
trap 'kill "$qpid" 2>/dev/null || true' EXIT

clean=$OUT/serial.clean.log
start=$SECONDS; result=timeout; failed=""
while (( SECONDS - start < TIMEOUT )); do
  oem_clean "$OUT/serial.log" "$clean"
  failed=$(oem_failed "$clean")
  if [ -n "$failed" ]; then result=boot_failed; break; fi
  if [ -z "$(oem_missing "$clean")" ]; then result=pass; break; fi
  kill -0 "$qpid" 2>/dev/null || { result=qemu_exited; break; }
  sleep 2
done
elapsed=$((SECONDS - start))

# Screenshot of what the first-boot session painted. Report-only: the number of distinct colours says whether the
# framebuffer is more than a blank screen; it does not prove the wizard is usable.
shot=none; colors=""
if kill -0 "$qpid" 2>/dev/null; then
  if [ "$result" = pass ]; then sleep "$settle"; fi
  if kill -0 "$qpid" 2>/dev/null; then
    f=$OUT/screenshot.ppm; case $f in /*) ;; *) f=$PWD/$f;; esac
    if python3 -I "$here/qmp.py" "$sock" screendump "{\"filename\":\"$f\"}" >/dev/null 2>&1; then
      shot=taken
      colors=$(python3 -I "$here/ppm-colors.py" "$OUT/screenshot.ppm" 2>/dev/null || true)
    else shot=failed; fi
  fi
  python3 -I "$here/qmp.py" "$sock" quit >/dev/null 2>&1 || true
fi
oem_clean "$OUT/serial.log" "$clean"
missing=$(oem_missing "$clean" | tr '\n' ' ' | sed 's/ $//')
[ "$result" != pass ] || [ -z "$missing" ] || result=missing_markers
if [ "$result" = pass ]; then  # a [FAILED] line that landed during the settle delay still fails the cell
  failed=$(oem_failed "$clean"); [ -z "$failed" ] || result=boot_failed
fi

# The first-boot session must still be alive after SETTLE: no core dump and no stopped user manager (markers.sh).
if [ "$result" = pass ]; then
  ended=$(oem_wizard_ended "$clean"); [ -z "$ended" ] || { result=wizard_session_ended; failed=$ended; }
fi

# A guest that passed its markers must still be running for the screenshot: QEMU exiting (guest reset, crash)
# before then, including during the settle delay, fails the cell instead of passing on old serial lines.
if [ "$result" = pass ] && [ "$shot" = none ]; then result=qemu_exited; fi

# Opt-in graphical gate (see MIN_COLORS above). With no screenshot there are no colours to count: that fails the gate.
min=${MIN_COLORS:-0}
if [ "$min" -gt 0 ] && { [ -z "$colors" ] || [ "$colors" -lt "$min" ]; }; then result="$result,screenshot-colors-${colors:-none}-below-$min"; fi

# The kernel must report the Secure Boot state that was asked for, or the cell proves nothing.
want=enabled; [ "$SECUREBOOT" = off ] && want=disabled
got=$(grep -aom1 'secureboot: Secure boot [a-z]*' "$clean" | awk '{print $NF}' || true)
if [ "$got" != "$want" ]; then result="$result,secureboot-${got:-unreported}"; fi
fail=1; [ "$result" = pass ] && fail=0

esc() { sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
name="oem-boot.$ARCH.sb-$SECUREBOOT"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  printf '<testsuite name="zeeos-oem-boot" tests="1" failures="%d" time="%d">\n' "$fail" "$elapsed"
  printf '<properties><property name="accel" value="%s"/><property name="arch" value="%s"/>' "$accel" "$ARCH"
  printf '<property name="secureboot" value="%s"/><property name="secureboot_kernel" value="%s"/>' "$SECUREBOOT" "${got:-unreported}"
  printf '<property name="boot_seconds" value="%d"/><property name="missing_markers" value="%s"/>' "$elapsed" "${missing:-none}"
  printf '<property name="screenshot" value="%s"/><property name="screenshot_colors" value="%s"/>' "$shot" "${colors:-n/a}"
  echo '</properties>'
  printf '<testcase classname="oem-boot" name="%s" time="%d">' "$name" "$elapsed"
  if [ "$fail" = 1 ]; then
    msg="$result; missing: ${missing:-none}"; [ -z "$failed" ] || msg="$msg; $failed"
    printf '<failure message="%s"/>' "$(printf '%s' "$msg" | esc)"
  fi
  echo '</testcase>'
  echo '</testsuite>'
} > "$OUT/junit.xml"
echo "$name: $result after ${elapsed}s (accel=$accel, kernel secure boot ${got:-unreported}, screenshot colors ${colors:-n/a}); results in $OUT"
exit "$fail"
