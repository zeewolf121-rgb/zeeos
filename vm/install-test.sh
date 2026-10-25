#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unattended install test (docs/phases/phase-4.md, P4-8): seed a disk, install ZeeOS onto it from the
# ISO, boot the installed system, and prove the pre-existing data survived.
# Env: ARCH=x86_64|aarch64  CASE=erase|luks|alongside|refuse-bitlocker|refuse-hibernated
#      ISO=<path>  OUT=<result dir>  SECUREBOOT=on|off (default on)
#      INSTALL_TIMEOUT (s, default 3600)  BOOT_TIMEOUT (s, default 900)
#      UNLOCK_TIMEOUT (s, default BOOT_TIMEOUT): the luks case waits this long for the passphrase prompt
#      VIRT_FW_VARS=<command> overrides virt-fw-vars (python virt-firmware 26.9), which alongside/refuse-* need
#      SEED_DIR=<dir with disk.img + seed.json> skips seeding (tests/install-selftest.sh)
#      QEMU_BIN / FW_CODE / FW_VARS override the emulator and firmware, as in vm/boot-test.sh
#      DRY_RUN=1 prints the seed plan (install-seed.py --dry-run) and every planned write and QEMU run,
#      then exits without creating or touching anything (not even OUT)
# Preset transport (#181): a raw virtio disk with serial ZEEOS-AUTOINSTALL whose first bytes are
# key=value lines (NUL-padded); the guest reads /dev/disk/by-id/virtio-ZEEOS-AUTOINSTALL.
# Writes OUT/{serial-install.log,serial-installed.log,checksums-*.json,nvram-*.json,junit.xml}. Only image files
# under OUT are ever written; OUT/disk.img must be a regular file.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ARCH=${ARCH:-x86_64}; CASE=${CASE:-erase}; SECUREBOOT=${SECUREBOOT:-on}
OUT=${OUT:-out/install-test/$ARCH-$CASE}; ISO=${ISO:-}
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-3600}; BOOT_TIMEOUT=${BOOT_TIMEOUT:-900}; UNLOCK_TIMEOUT=${UNLOCK_TIMEOUT:-$BOOT_TIMEOUT}
case $CASE in erase|luks|alongside|refuse-bitlocker|refuse-hibernated) ;; *) echo "bad CASE=$CASE" >&2; exit 2;; esac
case $SECUREBOOT in on|off) ;; *) echo "SECUREBOOT must be on|off" >&2; exit 2;; esac

first() { for f in "$@"; do [ -r "$f" ] && { echo "$f"; return 0; }; done; return 1; }
# Firmware: same choices as vm/boot-test.sh (kept in step by hand; see that file for the reasons).
case $ARCH in
  x86_64)
    qemu=qemu-system-x86_64; cpu=max
    machine=(-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on)
    if [ "$SECUREBOOT" = on ]; then
      code=$(first /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd || true)
      vars=$(first /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd /usr/share/OVMF/OVMF_VARS_4M.ms.fd /usr/share/OVMF/OVMF_VARS.secboot.fd || true)
    else
      code=$(first /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd || true)
      vars=$(first /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd || true)
    fi ;;
  aarch64)
    qemu=qemu-system-aarch64; cpu=max; machine=(-machine virt,gic-version=max)
    if [ "$SECUREBOOT" = on ]; then
      code=$(first /usr/share/AAVMF/AAVMF_CODE.ms.fd /usr/share/AAVMF/AAVMF_CODE.secboot.fd || true)
      vars=$(first /usr/share/AAVMF/AAVMF_VARS.ms.fd || true)
    else
      code=$(first /usr/share/AAVMF/AAVMF_CODE.no-secboot.fd /usr/share/AAVMF/AAVMF_CODE.fd || true)
      vars=$(first /usr/share/AAVMF/AAVMF_VARS.fd || true)
    fi ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2;;
esac
qemu=${QEMU_BIN:-$qemu}; code=${FW_CODE:-${code:-}}; vars=${FW_VARS:-${vars:-}}
# Installed system's serial console (#250), taken from the live ISO's kernelcmdline in
# build/arch/<arch>/config.xml, where arch differences live (rule 4); e.g. "tty0 ttyS0,115200".
console=$(sed -n 's/.*kernelcmdline="\([^"]*\)".*/\1/p' "$here/../build/arch/$ARCH/config.xml" 2>/dev/null \
  | tr ' ' '\n' | sed -n 's/^console=//p' | paste -sd' ' -)
[ -n "$console" ] || { echo "no console= in build/arch/$ARCH/config.xml kernelcmdline" >&2; exit 2; }
command -v "$qemu" >/dev/null || { echo "$qemu not installed" >&2; exit 2; }
[ -n "$code" ] && [ -n "$vars" ] || { echo "no $ARCH firmware (SB=$SECUREBOOT) found" >&2; exit 2; }
[ -n "$ISO" ] && [ -r "$ISO" ] || { echo "ISO not found; set ISO=<path>" >&2; exit 2; }
accel=tcg
if [ -w /dev/kvm ] && [ "$ARCH" = "$(uname -m)" ]; then accel=kvm; cpu=host
elif [ "$(uname -s)" = Darwin ] && [ "$ARCH" = "$(uname -m | sed s/arm64/aarch64/)" ]; then accel=hvf; cpu=host; fi
smp=2; if [ "$accel" = tcg ] && [ "$ARCH" = aarch64 ]; then cpu=max,pauth-impdef=on; smp=4; fi

case $OUT in /*) ;; *) OUT=$PWD/$OUT;; esac
disk=$OUT/disk.img
# Before anything is copied or seeded: cp and the seeder must never write through a symlink.
{ [ ! -L "$disk" ] && { [ ! -e "$disk" ] || [ -f "$disk" ]; }; } || { echo "$disk is not a regular file; refusing" >&2; exit 2; }
if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "install-test: dry-run: $CASE on $ARCH (accel=$accel, SECUREBOOT=$SECUREBOOT); nothing will be written"
  if [ -n "${SEED_DIR:-}" ]; then echo "  would copy $SEED_DIR/{disk.img,seed.json} to $OUT/"
  else python3 -I "$here/install-seed.py" --dry-run "$CASE" "$OUT"; fi
  echo "  would remove $OUT/{serial-*.log,checksums-*.json,junit.xml}"
  echo "  would write $OUT/{preset.conf,preset.img,vars.fd} (vars copied from $vars)"
  case $CASE in erase|luks) ;; *)
    echo "  would add a Windows Boot Manager Boot#### entry to $OUT/vars.fd (virt-fw-vars --inplace) and dump it to $OUT/nvram-before.json"
    echo "  would dump $OUT/vars.fd to $OUT/nvram-after.json after the install and compare (read only)";; esac
  [ "$CASE" != luks ] || echo "  would type the preset luks_passphrase at the unlock prompt of the installed boot (QMP send-key)"
  echo "  would hash the pre-existing data of $disk (read only)"
  echo "  would run $qemu with $code, $disk and $ISO (serial-install.log), then $disk alone (serial-installed.log)"
  echo "  would write $OUT/{checksums-*.json,junit.xml}"
  exit 0
fi
mkdir -p "$OUT"
rm -f "$OUT"/serial-*.log "$OUT"/checksums-*.json "$OUT"/nvram-*.json "$OUT"/nvram.stderr "$OUT"/junit.xml
# 1. Seed disk.
if [ -n "${SEED_DIR:-}" ]; then cp "$SEED_DIR/disk.img" "$SEED_DIR/seed.json" "$OUT/"
else python3 -I "$here/install-seed.py" "$CASE" "$OUT"; fi
[ -f "$disk" ] && [ ! -L "$disk" ] || { echo "$disk is not a regular file; refusing" >&2; exit 2; }
has_files=$(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(1 if s["files"] else 0)' "$OUT/seed.json")
has_parts=$(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(1 if s["partitions"] else 0)' "$OUT/seed.json")

# 2. Preset disk. The secrets are per run and stay in OUT (never committed).
pw=$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(12))')
luks_pw=$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(12))')
# console=: the installed system's kernel log and LUKS prompt reach serial-installed.log (#250).
printf 'case=%s\nuser=zee\npassword=%s\nluks_passphrase=%s\nconsole=%s\n' "$CASE" "$pw" "$luks_pw" "$console" > "$OUT/preset.conf"
cp "$OUT/preset.conf" "$OUT/preset.img"; python3 -I -c 'import os,sys; os.truncate(sys.argv[1], 1 << 20)' "$OUT/preset.img"

# 3. Checksums before.
cks() { python3 -I "$here/install-checksums.py" "$disk" "$OUT/seed.json" "$1" > "$OUT/checksums-$1-$2.json"; }
[ "$has_parts" = 0 ] || cks partitions before
if [ "$has_files" = 1 ]; then
  cks files before
  python3 -I "$here/install-checksums.py" "$disk" "$OUT/seed.json" manifest > "$OUT/checksums-files-seed.json"
fi

# 4. Two boots share one NVRAM vars file, so the installer's boot entry survives into the second.
cp "$vars" "$OUT/vars.fd"
# A fresh VARS template has no Windows Boot Manager entry (the firmware only adds its own), so for the cases
# with a Windows disk the harness writes one into the OUT copy, then snapshots NVRAM as the "before" state.
# Only that copy is ever written. Failures are recorded as results below, never skipped.
nvram=0; nvram_seed_msg=
case $CASE in erase|luks) ;; *)
  nvram=1
  if out=$(python3 -I "$here/install-nvram.py" seed-windows "$OUT/vars.fd" "$OUT/seed.json" 2>&1) \
     && python3 -I "$here/install-nvram.py" dump "$OUT/vars.fd" > "$OUT/nvram-before.json" 2>"$OUT/nvram.stderr"; then
    :
  else
    nvram_seed_msg="seeding NVRAM: $(echo "$out" | tail -n 3 | tr '\n' ' ')$( [ ! -f "$OUT/nvram.stderr" ] || tr '\n' ' ' < "$OUT/nvram.stderr")"
  fi ;;
esac
fwvars_ver=$(python3 -I "$here/install-nvram.py" version 2>/dev/null || true)
sock=$OUT/qmp.sock
base=(-accel "$accel" -cpu "$cpu" -m 4096 -smp "$smp" "${machine[@]}"
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$code"
  -drive "if=pflash,format=raw,unit=1,file=$OUT/vars.fd"
  -drive "file=$disk,if=virtio,format=raw"
  -device virtio-gpu-pci -device qemu-xhci -device usb-kbd
  -display none -qmp "unix:$sock,server=on,wait=off" -no-reboot)
qpid=
trap '[ -z "$qpid" ] || kill "$qpid" 2>/dev/null || true' EXIT
launch() { # serial-log extra-args...
  local log=$1; shift
  rm -f "$sock"; : > "$log"
  "$qemu" "${base[@]}" -serial "file:$log" "$@" 2>>"$OUT/qemu.stderr" &
  qpid=$!
}
stop() { python3 -I "$here/qmp.py" "$sock" quit >/dev/null 2>&1 || true; wait "$qpid" 2>/dev/null || true; qpid=; }
# wait_for LOG OK_RE FAIL_RE TIMEOUT -> 0 ok, 1 fail line, 2 timeout, 3 QEMU exited first
wait_for() {
  local t=$SECONDS
  while (( SECONDS - t < $4 )); do
    grep -aqE -- "$2" "$1" && return 0
    grep -aqE -- "$3" "$1" && return 1
    kill -0 "$qpid" 2>/dev/null || { grep -aqE -- "$2" "$1" && return 0; return 3; }
    sleep 2
  done
  return 2
}

# results[i] for checks[i]: ok | skipped:<why> | <failure>
checks=(); results=()
record() { checks+=("$1"); results+=("$2"); }
# The guest kernel must report the Secure Boot state that was asked for, as in vm/boot-test.sh.
want_sb=enabled; [ "$SECUREBOOT" = off ] && want_sb=disabled
check_sb() { # name serial-log
  local got; got=$(grep -aom1 'secureboot: Secure boot [a-z]*' "$2" | awk '{print $NF}' || true)
  if [ "$got" = "$want_sb" ]; then record "$1" ok; else record "$1" "Secure Boot ${got:-unreported}, want $want_sb"; fi
}

start=$SECONDS
# The preset disk's serial is a virtio-blk device property: QEMU 8.2 (ubuntu-24.04) rejects
# `-drive ...,serial=` ("Block format 'raw' does not support the option 'serial'") and exits.
launch "$OUT/serial-install.log" -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=$OUT/preset.img,if=none,id=zeepreset,format=raw,readonly=on" \
  -device "virtio-blk-pci,drive=zeepreset,serial=ZEEOS-AUTOINSTALL"
rc=0; wait_for "$OUT/serial-install.log" '^ZEEOS_INSTALL_DONE' '^ZEEOS_INSTALL_FAIL' "$INSTALL_TIMEOUT" || rc=$?
fail_line=$(grep -aom1 '^ZEEOS_INSTALL_FAIL.*' "$OUT/serial-install.log" || true)
case $CASE in
  refuse-*)
    if [ "$rc" = 1 ] && [[ "$fail_line" == "ZEEOS_INSTALL_FAIL preflight:"* ]]; then record install ok
    elif [ "$rc" = 0 ]; then record install "installed although the case must be refused"
    else record install "want ZEEOS_INSTALL_FAIL preflight, got ${fail_line:-rc=$rc}"; fi ;;
  *)
    if [ "$rc" = 0 ]; then record install ok
    elif [ "$rc" = 1 ]; then record install "${fail_line#ZEEOS_INSTALL_FAIL }"
    elif [ "$rc" = 2 ]; then record install "timeout after ${INSTALL_TIMEOUT}s"
    else record install "QEMU exited without ZEEOS_INSTALL_DONE"; fi ;;
esac
# The guest powers off after DONE/FAIL; give it a minute, then stop QEMU ourselves.
t=$SECONDS; while kill -0 "$qpid" 2>/dev/null && (( SECONDS - t < 60 )); do sleep 2; done; stop
check_sb secureboot-install "$OUT/serial-install.log"
# NVRAM after the install, read from the stopped VM's VARS copy (the installed boot comes later, so firmware
# noise from it can't mask what the installer did). Windows Boot Manager must survive; alongside puts ZeeOS
# first in BootOrder; refuse leaves the old entries alone (rules: vm/install-nvram.py).
if [ "$nvram" = 1 ]; then
  if [ -n "$nvram_seed_msg" ]; then record nvram "$nvram_seed_msg"
  elif ! out=$(python3 -I "$here/install-nvram.py" dump "$OUT/vars.fd" 2>&1 > "$OUT/nvram-after.json"); then
    record nvram "reading NVRAM: $(echo "$out" | tail -n 3 | tr '\n' ' ')"
  elif out=$(python3 -I "$here/install-nvram.py" check "$CASE" "$OUT/nvram-before.json" "$OUT/nvram-after.json"); then
    record nvram ok
  else record nvram "$(echo "$out" | tr '\n' ' ')"; fi
fi

# 5. Boot the installed system (cases that install). The luks case first meets the unlock prompt: the
# passphrase is typed through QMP send-key (vm/qmp.py type), because the guest's prompt is answered from a
# keyboard (usb-kbd here): plymouth and systemd-ask-password both read the console/VT input, and the serial
# chardev is a plain output file. No prompt, or a prompt the passphrase doesn't open, fails the cell.
installed=0
if [ "${results[0]}" = ok ] && [[ "$CASE" != refuse-* ]]; then
  installed=1
  launch "$OUT/serial-installed.log"
  slog=$OUT/serial-installed.log
  rc=0
  if [ "$CASE" = luks ]; then
    prompt_re='[Pp]lease enter passphrase|[Ee]nter passphrase for|[Pp]assphrase for |Please enter .*(passphrase|password)'
    wait_for "$slog" "$prompt_re|^ZEEOS_DESKTOP_READY" '^ZEEOS_[A-Z_]*FAIL' "$UNLOCK_TIMEOUT" || rc=$?
    if [ "$rc" = 0 ] && grep -aqE -- "$prompt_re" "$slog"; then
      sleep 3  # the prompt is printed just before the agent starts reading
      typing=$(python3 -I -c 'import json,sys
for l in open(sys.argv[1]):
    if l.startswith("luks_passphrase="): print(json.dumps({"text": l.split("=", 1)[1].rstrip("\n"), "enter": True}))' "$OUT/preset.conf")
      if python3 -I "$here/qmp.py" "$sock" type "$typing" >/dev/null; then
        rc=0; wait_for "$slog" '^ZEEOS_DESKTOP_READY' '^ZEEOS_[A-Z_]*FAIL' "$BOOT_TIMEOUT" || rc=$?
        if [ "$rc" = 0 ]; then record unlock ok; else record unlock "passphrase typed, but the system did not come up (rc=$rc)"; fi
      else record unlock "could not type the passphrase through QMP"; rc=9; fi
    elif [ "$rc" = 0 ]; then
      record unlock "reached the login screen without a passphrase prompt: root is not encrypted"
    elif [ "$rc" = 1 ]; then record unlock "$(grep -aom1 '^ZEEOS_[A-Z_]*FAIL.*' "$slog") before any passphrase prompt"
    elif [ "$rc" = 2 ]; then record unlock "no passphrase prompt on the serial console after ${UNLOCK_TIMEOUT}s"
    else record unlock "QEMU exited before a passphrase prompt"; fi
  else
    wait_for "$slog" '^ZEEOS_DESKTOP_READY' '^ZEEOS_[A-Z_]*FAIL' "$BOOT_TIMEOUT" || rc=$?
  fi
  if [ "$rc" = 0 ]; then record boot ok; else record boot "installed system: no ZEEOS_DESKTOP_READY (rc=$rc)"; fi
  stop
  check_sb secureboot-installed "$slog"
  bm=$(grep -aom1 '^ZEEOS_BOOTMENU .*' "$slog" | tr -d '\r' || true)
  want_win=0; [ "$CASE" = alongside ] && want_win=1
  if [[ "$bm" == *"zeeos=1"* && "$bm" == *"windows=$want_win"* ]]; then record bootmenu ok
  else record bootmenu "want zeeos=1 windows=$want_win, got '${bm:-no ZEEOS_BOOTMENU}'"; fi
  rf=$(grep -aom1 '^ZEEOS_ROOTFS .*' "$slog" | tr -d '\r' || true)
  want_luks=0; [ "$CASE" = luks ] && want_luks=2
  if [[ " $rf " == *" luks=$want_luks "* ]]; then record rootfs ok
  else record rootfs "want luks=$want_luks (0 = none, 2 = LUKS2), got '${rf:-no ZEEOS_ROOTFS}'"; fi
fi

# 6. Checksums after: whole partitions must match for the refuse cases, files for alongside.
if [[ "$CASE" == refuse-* ]]; then
  cks partitions after
  if out=$(python3 -I "$here/install-checksums.py" compare "$OUT/checksums-partitions-before.json" "$OUT/checksums-partitions-after.json"); then
    record checksums ok; else record checksums "pre-existing partitions changed: $(echo "$out" | tr '\n' ' ')"; fi
elif [ "$CASE" = alongside ]; then
  # The real post-install GPT first: both copies valid, the disk not truncated, ESP/MSR/Windows
  # still there with the same type, GUID and start (Windows may only shrink). Bytes at the seed's
  # offsets prove nothing if the table no longer points at them.
  layout_ok=0
  if out=$(python3 -I "$here/install-checksums.py" "$disk" "$OUT/seed.json" layout); then
    record layout ok; layout_ok=1; else record layout "partition table: $(echo "$out" | tr '\n' ' ')"; fi
  if [ "$has_files" = 1 ] && [ "$installed" = 1 ] && [ "$layout_ok" = 1 ]; then
    # The baseline must be what install-seed.py wrote, and readable, or "unchanged" proves nothing.
    if out=$(python3 -I "$here/install-checksums.py" compare "$OUT/checksums-files-seed.json" "$OUT/checksums-files-before.json"); then
      record seed-files ok; else record seed-files "baseline differs from seed.json: $(echo "$out" | tr '\n' ' ')"; fi
    cks files after
    if out=$(python3 -I "$here/install-checksums.py" compare "$OUT/checksums-files-before.json" "$OUT/checksums-files-after.json"); then
      record checksums ok; else record checksums "pre-existing files changed: $(echo "$out" | tr '\n' ' ')"; fi
  elif [ "$has_files" = 1 ] && [ "$layout_ok" = 0 ]; then
    record checksums "not checked: the partition table was rejected"
  fi
fi
elapsed=$((SECONDS - start))

# 7. junit: one testcase per check; skipped stays skipped.
name="install.$ARCH.$CASE"; nfail=0; nskip=0
for r in "${results[@]}"; do case $r in ok) ;; skipped:*) nskip=$((nskip + 1));; *) nfail=$((nfail + 1));; esac; done
xml() { sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  printf '<testsuite name="zeeos-install" tests="%d" failures="%d" skipped="%d" time="%d">\n' "${#checks[@]}" "$nfail" "$nskip" "$elapsed"
  printf '<properties><property name="accel" value="%s"/><property name="arch" value="%s"/><property name="case" value="%s"/><property name="secureboot" value="%s"/>' "$accel" "$ARCH" "$CASE" "$SECUREBOOT"
  [ -z "$fwvars_ver" ] || printf '<property name="virt_firmware" value="%s"/>' "$fwvars_ver"
  echo '</properties>'
  for i in "${!checks[@]}"; do
    printf '<testcase classname="install" name="%s.%s">' "$name" "${checks[$i]}"
    case ${results[$i]} in
      ok) ;;
      skipped:*) printf '<skipped message="%s"/>' "$(xml "${results[$i]#skipped:}")" ;;
      *) printf '<failure message="%s"/>' "$(xml "${results[$i]}")" ;;
    esac
    echo '</testcase>'
  done
  echo '</testsuite>'
} > "$OUT/junit.xml"
for i in "${!checks[@]}"; do echo "$name ${checks[$i]}: ${results[$i]}"; done
echo "$name: $nfail failed, $nskip skipped after ${elapsed}s (accel=$accel); results in $OUT"
[ "$nfail" = 0 ]
