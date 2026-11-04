#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline checks of vm/utm/make-bundle.sh and vm/utm/utm-test.sh (#278): dry runs, a fixture bundle built from a stand-in
# disk, plist validation and serial-log replay through a fake QEMU. Nothing boots; the real run is the Mac cell.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
die() { echo "FAIL: $*" >&2; exit 1; }

# qemu-img shim: creates an empty file named by the last argument. fake QEMU as in selftest.sh.
# shellcheck disable=SC2016  # the $ expressions belong to the shim script
printf '#!/bin/sh\nfor a; do last=$a; done; printf x > "$last"\n' > "$tmp/qemu-img"
printf '#!/bin/sh\nexec python3 -I "%s" "$@"\n' "$PWD/tests/fake-qemu.py" > "$tmp/qemu"
chmod +x "$tmp/qemu-img" "$tmp/qemu"
fw=$tmp/fw; : > "$fw"

# make-bundle: dry run writes nothing and prints the pipeline.
out=$(DRY_RUN=1 VERSION=1.2.3 OUT="$tmp/dry" vm/utm/make-bundle.sh)
for pat in 'convert -c -f raw -O qcow2' 'utm-config.py render' 'utm-config.py zip' 'zeeos-1.2.3-aarch64.utm.zip'; do
  grep -q -- "$pat" <<<"$out" || die "dry run lacks '$pat'"
done
[ ! -e "$tmp/dry" ] || die "dry run wrote files"
if VERSION='a b' DRY_RUN=1 vm/utm/make-bundle.sh >/dev/null 2>&1; then die "bad VERSION accepted"; fi
if DISK="$tmp/nonexistent" OUT="$tmp/x" vm/utm/make-bundle.sh >/dev/null 2>&1; then die "missing disk accepted"; fi

# make-bundle: fixture build and layout.
disk=$tmp/oem.raw; printf 'raw' > "$disk"
VERSION=1.2.3 DISK=$disk OUT=$tmp/b QEMU_IMG=$tmp/qemu-img vm/utm/make-bundle.sh >/dev/null
b=$tmp/b/zeeos-1.2.3-aarch64.utm
[ -s "$b/config.plist" ] && [ -f "$b/Data/zeeos-1.2.3-aarch64.qcow2" ] && [ -f "$tmp/b/zeeos-1.2.3-aarch64.utm.zip" ] || die "bundle layout"
python3 -I - "$b/config.plist" "$tmp/b/zeeos-1.2.3-aarch64.utm.zip" <<'PY'
import plistlib, sys, zipfile
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["System"]["MemorySize"] == 4096 and p["System"]["CPUCount"] == 4 and p["System"]["Target"] == "virt"
assert p["Backend"] == "QEMU" and p["System"]["Boot"]["UEFIBoot"] is True
assert p["Drive"][0]["ImageName"] == "zeeos-1.2.3-aarch64.qcow2"
assert p["Display"][0]["Hardware"] == "virtio-gpu-pci" and p["Network"][0]["Hardware"] == "virtio-net-pci"
assert p["Sharing"]["ClipboardSharing"] is True
names = zipfile.ZipFile(sys.argv[2]).namelist()
assert names == ["zeeos-1.2.3-aarch64.utm/Data/zeeos-1.2.3-aarch64.qcow2", "zeeos-1.2.3-aarch64.utm/config.plist"], names
PY
VERSION=1.2.3 DISK=$disk OUT=$tmp/b2 QEMU_IMG=$tmp/qemu-img vm/utm/make-bundle.sh >/dev/null
cmp "$tmp/b/zeeos-1.2.3-aarch64.utm.zip" "$tmp/b2/zeeos-1.2.3-aarch64.utm.zip" || die "zip is not reproducible"

# A zip with a path escape is refused.
python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "w").writestr("../evil", "x")' "$tmp/evil.zip"
if python3 -I vm/utm/utm-config.py unzip "$tmp/evil.zip" "$tmp/evil-dest" 2>/dev/null; then die "unsafe zip accepted"; fi
mkdir -p "$tmp/evil-dest" && ! python3 -I vm/utm/utm-config.py unzip "$tmp/evil.zip" "$tmp/evil-dest" 2>/dev/null || die "unsafe zip accepted"

# utm-test dry run uses the plist's values.
out=$(DRY_RUN=1 BUNDLE=$tmp/b/zeeos-1.2.3-aarch64.utm.zip OUT=$tmp/dry-t FW_CODE=$fw FW_VARS=$fw vm/utm/utm-test.sh)
for pat in 'qemu-system-aarch64' '-m 4096' '-smp 4' '-machine virt' 'virtio-gpu-pci' 'virtio-net-pci' 'overlay.qcow2'; do
  grep -q -- "$pat" <<<"$out" || die "utm-test dry run lacks '$pat': $out"
done
if grep -q 'media=cdrom' <<<"$out"; then die "utm-test attached an ISO"; fi
if BUNDLE=$tmp/nonexistent vm/utm/utm-test.sh >/dev/null 2>&1; then die "missing bundle accepted"; fi

# utm_replay <fixture> <pass|fail> <env assignment or -> <junit pattern>...
utm_replay() {
  local fx=$1 want=$2 extra=$3 o rc=0; shift 3
  o=$tmp/t-${fx%.log}-${extra//[^a-z0-9]/}
  env FAKE_SERIAL=tests/fixtures/$fx QEMU_BIN=$tmp/qemu QEMU_IMG=$tmp/qemu-img FW_CODE=$fw FW_VARS=$fw \
    BUNDLE=$tmp/b/zeeos-1.2.3-aarch64.utm.zip OUT=$o SETTLE=0 TIMEOUT=6 HARDENING_TIMEOUT=3 ${extra/#-/X=} \
    vm/utm/utm-test.sh >"$o.log" 2>&1 || rc=$?
  if { [ "$want" = pass ] && [ "$rc" != 0 ]; } || { [ "$want" = fail ] && [ "$rc" = 0 ]; }; then
    cat "$o.log" >&2; die "$fx expected $want, exit $rc"
  fi
  for pat in "$@"; do grep -q -- "$pat" "$o/junit.xml" || { cat "$o/junit.xml" >&2; die "$fx: junit lacks '$pat'"; }; done
}
utm_replay serial-oem-ok.log pass - 'failures="0"' 'hardening" value="none"' 'plist_memory" value="4096"' 'plist_cpus" value="4"'
utm_replay serial-oem-sb-on.log pass - 'secureboot_kernel" value="enabled"'
utm_replay serial-oem-ok.log pass - 'secureboot_kernel" value="disabled"'
utm_replay serial-oem-hardening-ok.log pass - 'hardening" value="ok"'
utm_replay serial-oem-hardening-ok.log pass REQUIRE_HARDENING=1 'hardening" value="ok"'
utm_replay serial-oem-ok.log fail REQUIRE_HARDENING=1 'hardening-timeout'
utm_replay serial-oem-hardening-liveoff.log fail - 'autoupdate=on'
utm_replay serial-oem-hardening-fail.log fail - 'hardening-fail' 'firewall: inactive'
utm_replay serial-oem-hardening-missing.log fail - 'hardening-timeout'
utm_replay serial-oem-no-sddm.log fail - 'missing_markers" value="sddm"'
utm_replay serial-oem-failed.log fail - 'boot_failed'
utm_replay serial-oem-wizard-died.log fail - 'wizard_session_ended'
echo "utm selftest ok"
