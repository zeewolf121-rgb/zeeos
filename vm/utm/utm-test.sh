#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unpack a ZeeOS UTM bundle and boot ITS disk with QEMU (+ HVF on the Apple silicon Mac), using the machine, CPU count,
# memory and devices read from the bundle's config.plist and UTM's own edk2 firmware. Checks the first-boot markers.
# Env: BUNDLE=<zeeos-<ver>-aarch64.utm.zip or .utm directory, required>  OUT=<result dir>  TIMEOUT=<s, 600; 1800 under TCG>
#      SETTLE=<s from the last marker to the screenshot, 30; 120 under TCG>  HARDENING_TIMEOUT=<s, 120>
#      REQUIRE_HARDENING=1 fail unless ZEEOS_HARDENING_OK ... autoupdate=on appears (see below)  DRY_RUN=1 (print command)
#      MIN_COLORS=<n> fail unless the final screenshot has at least n distinct colours (default 0: report only)
#      UTM_APP=<UTM.app, default /Applications/UTM.app> supplies edk2-aarch64-code.fd and edk2-arm-vars.fd;
#      FW_CODE / FW_VARS / QEMU_BIN / QEMU_IMG override firmware and tools (offline tests/selftest.sh)
# Markers: the bundle's disk is the oem disk, which has no user before the plasma-setup wizard, so ZEEOS_DESKTOP_READY cannot
# be printed (see vm/README.md, #277). The pass marker is OEM_MARKERS (vm/markers.sh). If the guest announces
# ZEEOS_HARDENING_CHECK (or REQUIRE_HARDENING=1), ZEEOS_HARDENING_OK with autoupdate=on must follow: an installed system
# gets autoupdate=on, and any other value or a ZEEOS_HARDENING_FAIL fails the cell.
# Secure Boot: UTM's firmware is not assumed to enforce it. The guest kernel's state is recorded in junit
# (secureboot_kernel) and OUT/secureboot, and is not a pass condition.
# Writes OUT/{serial.log,serial.clean.log,screenshot.ppm,junit.xml,accel,secureboot,config.show}. The bundle's disk is
# attached through a qcow2 overlay, so it is never modified.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../markers.sh
. "$here/../markers.sh"
BUNDLE=${BUNDLE:-}; OUT=${OUT:-out/utm-test}; DRY_RUN=${DRY_RUN:-0}
UTM_APP=${UTM_APP:-/Applications/UTM.app}
qemu=${QEMU_BIN:-qemu-system-aarch64}; qimg=${QEMU_IMG:-qemu-img}
[ -n "$BUNDLE" ] && [ -e "$BUNDLE" ] || { echo "bundle not found; set BUNDLE=<.utm.zip or .utm dir>" >&2; exit 2; }
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
# Absolute: the overlay names the bundle disk as its backing file, which qemu-img resolves against the overlay's
# directory, not ours.
if [ -d "$BUNDLE" ]; then utm=$(cd "$BUNDLE" && pwd)
else
  rm -rf "$OUT/unpacked"; mkdir -p "$OUT/unpacked"
  python3 -I "$here/utm-config.py" unzip "$BUNDLE" "$OUT/unpacked"
  utm=$(find "$OUT/unpacked" -maxdepth 1 -name '*.utm' -type d | head -n1)
  [ -n "$utm" ] || { echo "no .utm directory in $BUNDLE" >&2; exit 2; }
fi
[ -r "$utm/config.plist" ] || { echo "no config.plist in $utm" >&2; exit 2; }
python3 -I "$here/utm-config.py" show "$utm/config.plist" > "$OUT/config.show"
cfg() { sed -n "s/^$1=//p" "$OUT/config.show"; }
image=$utm/Data/$(cfg DISK); [ -r "$image" ] || { echo "bundle disk $image missing" >&2; exit 2; }

code=${FW_CODE:-$UTM_APP/Contents/Resources/qemu/edk2-aarch64-code.fd}
vars=${FW_VARS:-}
if [ -z "$vars" ]; then
  if [ -r "$utm/Data/efi_vars.fd" ]; then vars=$utm/Data/efi_vars.fd; else vars=$UTM_APP/Contents/Resources/qemu/edk2-arm-vars.fd; fi
fi
if [ "$DRY_RUN" != 1 ]; then
  command -v "$qemu" >/dev/null || [ -x "$qemu" ] || { echo "$qemu not installed" >&2; exit 2; }
  [ -r "$code" ] && [ -r "$vars" ] || { echo "UTM firmware not found ($code, $vars); set UTM_APP or FW_CODE/FW_VARS" >&2; exit 2; }
fi

# Same acceleration rule as vm/oem-boot-test.sh. The plist asks for the hypervisor; only a Mac or KVM host can give it.
accel=tcg; cpu=max
if [ -w /dev/kvm ] && [ "$(uname -m)" = aarch64 ]; then accel=kvm; cpu=host
elif [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then accel=hvf; cpu=host; fi
tmo=600; settle=${SETTLE:-30}
if [ "$accel" = tcg ]; then cpu=max,pauth-impdef=on; tmo=1800; settle=${SETTLE:-120}; fi
TIMEOUT=${TIMEOUT:-$tmo}; HTMO=${HARDENING_TIMEOUT:-120}

# The QMP socket lives in a short temp dir: a Unix socket path must stay under 104 bytes on macOS, and OUT may be deep.
sockdir=$(mktemp -d /tmp/zq.XXXXXX)
trap 'rm -rf "$sockdir"' EXIT
sock=$sockdir/qmp.sock
args=(-accel "$accel" -cpu "$cpu" -m "$(cfg MEMORY)" -smp "$(cfg CPUS)" -machine "$(cfg TARGET),gic-version=max"
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$code"
  -drive "if=pflash,format=raw,unit=1,file=$OUT/vars.fd"
  -drive "file=$OUT/overlay.qcow2,if=virtio,format=qcow2"
  -device "$(cfg GPU)" -device "virtio-net-pci,netdev=n0" -netdev user,id=n0
  -device qemu-xhci -device usb-kbd)
[ "$(cfg RNG)" != 1 ] || args+=(-device virtio-rng-pci)
args+=(-serial "file:$OUT/serial.log" -display none -qmp "unix:$sock,server=on,wait=off" -no-reboot)
if [ "$DRY_RUN" = 1 ]; then echo "$qemu ${args[*]}"; exit 0; fi

echo "$accel" > "$OUT/accel"
rm -f "$OUT"/screenshot*.ppm "$sock"
"$qimg" create -q -f qcow2 -b "$image" -F qcow2 "$OUT/overlay.qcow2"
cp "$vars" "$OUT/vars.fd"; : > "$OUT/serial.log"
# UTM ships its vars store unpadded (edk2-arm-vars.fd is ~320 KiB); QEMU's virt pflash1 must match pflash0's size. The
# pad is the erased-flash state, so only the working copy grows.
csize=$(wc -c <"$code" | tr -d ' '); vsize=$(wc -c <"$OUT/vars.fd" | tr -d ' ')
if [ "$vsize" -lt "$csize" ]; then
  python3 -I -c 'import sys; f=open(sys.argv[1],"ab"); f.write(b"\0"*(int(sys.argv[2])-f.tell()))' "$OUT/vars.fd" "$csize"
fi
"$qemu" "${args[@]}" 2>"$OUT/qemu.stderr" &
qpid=$!
trap 'kill "$qpid" 2>/dev/null || true; rm -rf "$sockdir"' EXIT

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

# Hardening: required when announced or asked for; waits up to HARDENING_TIMEOUT after the boot markers.
# Run again after the settle interval, so an announcement (and failure) that arrives late is not ignored.
hstate=none; hmsg=""
check_hardening() {
  [ "$result" = pass ] && [ "$hstate" = none ] || return 0
  if [ "${REQUIRE_HARDENING:-0}" = 1 ] || grep -aq '^ZEEOS_HARDENING_CHECK' "$OUT/serial.log"; then
    hardening_wait "$OUT/serial.log" "$HTMO" "$qpid" || true
    hstate=$(hardening_state "$OUT/serial.log" 1)
    [ "$hstate" != none ] || hstate=timeout  # asked for but never announced
    if [ "$hstate" = ok ]; then
      grep -aq '^ZEEOS_HARDENING_OK .*autoupdate=on' "$OUT/serial.log" || { hstate=fail; hmsg="ZEEOS_HARDENING_OK without autoupdate=on"; }
    fi
    [ -n "$hmsg" ] || hmsg=$(hardening_msg "$hstate" "$OUT/serial.log")
    [ "$hstate" = ok ] || result="hardening-$hstate"
  fi
}
check_hardening
elapsed=$((SECONDS - start))

shot=none; colors=""
if kill -0 "$qpid" 2>/dev/null; then
  if [ "$result" = pass ]; then sleep "$settle"; check_hardening; fi
  if kill -0 "$qpid" 2>/dev/null; then
    if python3 -I "$here/../qmp.py" "$sock" screendump "{\"filename\":\"$OUT/screenshot.ppm\"}" >/dev/null 2>&1; then
      shot=taken
      colors=$(python3 -I "$here/../ppm-colors.py" "$OUT/screenshot.ppm" 2>/dev/null || true)
    else shot=failed; fi
  fi
  python3 -I "$here/../qmp.py" "$sock" quit >/dev/null 2>&1 || true
fi
oem_clean "$OUT/serial.log" "$clean"
missing=$(oem_missing "$clean" | tr '\n' ' ' | sed 's/ $//')
[ "$result" != pass ] || [ -z "$missing" ] || result=missing_markers
if [ "$result" = pass ]; then
  failed=$(oem_failed "$clean"); [ -z "$failed" ] || result=boot_failed
fi
if [ "$result" = pass ]; then
  ended=$(oem_wizard_ended "$clean"); [ -z "$ended" ] || { result=wizard_session_ended; failed=$ended; }
fi
if [ "$result" = pass ] && [ "$shot" = none ]; then result=qemu_exited; fi
if [ "$result" = pass ] && grep -aq '^ZEEOS_HARDENING_FAIL' "$OUT/serial.log"; then
  hstate=fail; hmsg=$(hardening_msg fail "$OUT/serial.log"); result=hardening-fail
fi

# Opt-in graphical gate, as in vm/oem-boot-test.sh: the wizard must have painted (a text console has 2 colours).
# With no screenshot there are no colours to count: that fails the gate.
min=${MIN_COLORS:-0}
if [ "$min" -gt 0 ] && { [ -z "$colors" ] || [ "$colors" -lt "$min" ]; }; then result="$result,screenshot-colors-${colors:-none}-below-$min"; fi

got=$(grep -aom1 'secureboot: Secure boot [a-z]*' "$clean" | awk '{print $NF}' || true)
echo "${got:-unreported}" > "$OUT/secureboot"
fail=1; [ "$result" = pass ] && fail=0

esc() { sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
name="utm-boot.aarch64"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  printf '<testsuite name="zeeos-utm-test" tests="1" failures="%d" time="%d">\n' "$fail" "$elapsed"
  printf '<properties><property name="accel" value="%s"/><property name="arch" value="aarch64"/>' "$accel"
  printf '<property name="secureboot_kernel" value="%s"/><property name="hardening" value="%s"/>' "${got:-unreported}" "$hstate"
  printf '<property name="plist_cpus" value="%s"/><property name="plist_memory" value="%s"/>' "$(cfg CPUS)" "$(cfg MEMORY)"
  printf '<property name="boot_seconds" value="%d"/><property name="missing_markers" value="%s"/>' "$elapsed" "${missing:-none}"
  printf '<property name="screenshot" value="%s"/><property name="screenshot_colors" value="%s"/>' "$shot" "${colors:-n/a}"
  echo '</properties>'
  printf '<testcase classname="utm-boot" name="%s" time="%d">' "$name" "$elapsed"
  if [ "$fail" = 1 ]; then
    msg="$result; missing: ${missing:-none}"; [ -z "$failed" ] || msg="$msg; $failed"; [ -z "$hmsg" ] || msg="$msg; $hmsg"
    printf '<failure message="%s"/>' "$(printf '%s' "$msg" | esc)"
  fi
  echo '</testcase>'
  echo '</testsuite>'
} > "$OUT/junit.xml"
echo "$name: $result after ${elapsed}s (accel=$accel, kernel secure boot ${got:-unreported}, hardening $hstate); results in $OUT"
exit "$fail"
