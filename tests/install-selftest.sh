#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline checks of vm/install-test.sh (P4-8): replay serial fixtures through a fake QEMU on tiny seed
# disks. Needs only bash and python3 (no QEMU, no disk tools), so it runs on a stock runner.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fx=tests/fixtures
printf '#!/bin/sh\nexec python3 -I "%s" "$@"\n' "$PWD/tests/fake-qemu.py" > "$tmp/qemu"; chmod +x "$tmp/qemu"
: > "$tmp/code.fd"; : > "$tmp/vars.fd"; : > "$tmp/fake.iso"

# seed <dir> <with-partitions:0|1>: a 64 KiB disk; with partitions, two 16 KiB ranges of known bytes.
seed() {
  mkdir -p "$1"
  python3 -I - "$1" "$2" <<'EOF'
import json, os, sys
d, parts = sys.argv[1], sys.argv[2] == "1"
with open(os.path.join(d, "disk.img"), "wb") as f:
    f.write(bytes(range(256)) * 256)
p = [{"name": "esp", "offset": 4096, "size": 16384}, {"name": "windows", "offset": 32768, "size": 16384}]
json.dump({"case": "t", "size": 65536, "partitions": p if parts else [], "files": {}}, open(os.path.join(d, "seed.json"), "w"))
EOF
}
seed "$tmp/blank" 0; seed "$tmp/win" 1

# run <name> <case> <seed> <install fixture> <installed fixture> <expect pass|fail> [junit pattern...]
run() {
  local name=$1 case=$2 sd=$3 fi=$4 fd=$5 want=$6 o rc=0; shift 6
  o=$tmp/out-$name
  FAKE_SERIAL_INSTALL=$fx/$fi FAKE_SERIAL_INSTALLED=$fx/$fd FAKE_POWEROFF=1 QEMU_BIN=$tmp/qemu \
    FW_CODE=$tmp/code.fd FW_VARS=$tmp/vars.fd ISO=$tmp/fake.iso SEED_DIR=$sd OUT=$o ARCH=x86_64 CASE=$case \
    INSTALL_TIMEOUT=10 BOOT_TIMEOUT=10 vm/install-test.sh >"$o.log" 2>&1 || rc=$?
  if { [ "$want" = pass ] && [ "$rc" != 0 ]; } || { [ "$want" = fail ] && [ "$rc" = 0 ]; }; then
    echo "FAIL: $name expected $want, exit $rc" >&2; cat "$o.log" >&2; exit 1
  fi
  for pat in "$@"; do
    grep -q -- "$pat" "$o/junit.xml" || { echo "FAIL: $name: junit lacks '$pat'" >&2; cat "$o/junit.xml" >&2; exit 1; }
  done
}

run erase-ok erase "$tmp/blank" serial-install-done.log serial-installed-ok.log pass \
  'failures="0"' 'name="install.x86_64.erase.bootmenu"' 'name="install.x86_64.erase.rootfs"'
run erase-install-fail erase "$tmp/blank" serial-install-fail.log serial-installed-ok.log fail 'partition: no space'
run luks-skips-boot luks "$tmp/blank" serial-install-done.log serial-installed-ok.log pass \
  'skipped="1"' 'LUKS passphrase entry at boot not implemented'
run refuse-ok refuse-bitlocker "$tmp/win" serial-install-refused.log serial-installed-ok.log pass \
  'failures="0"' 'name="install.x86_64.refuse-bitlocker.checksums"' 'Windows Boot Manager NVRAM check'
FAKE_FLIP=$((32768 + 100)) run refuse-disk-changed refuse-bitlocker "$tmp/win" serial-install-refused.log \
  serial-installed-ok.log fail 'pre-existing partitions changed'
run refuse-but-installed refuse-hibernated "$tmp/win" serial-install-done.log serial-installed-ok.log fail \
  'installed although the case must be refused'
run alongside-no-windows-entry alongside "$tmp/win" serial-install-done.log serial-installed-ok.log fail \
  'want zeeos=1 windows=1'
run alongside-ok alongside "$tmp/win" serial-install-done.log serial-installed-windows.log pass 'failures="0"'
FAKE_FLIP=512 run refuse-gpt-changed refuse-bitlocker "$tmp/win" serial-install-refused.log \
  serial-installed-ok.log fail 'gpt-primary'
run installed-without-secureboot erase "$tmp/blank" serial-install-done.log serial-installed-nosb.log fail \
  'Secure Boot unreported, want enabled'
[ -s "$tmp/out-refuse-ok/checksums-partitions-before.json" ] || { echo "FAIL: no partition checksums" >&2; exit 1; }
# A symlinked seed target is refused before anything is written through it.
mkdir -p "$tmp/sym"; echo precious > "$tmp/victim"; ln -s "$tmp/victim" "$tmp/sym/disk.img"
if python3 -I vm/install-seed.py erase "$tmp/sym" 2>/dev/null; then echo "FAIL: symlinked disk.img accepted" >&2; exit 1; fi
[ "$(cat "$tmp/victim")" = precious ] || { echo "FAIL: symlink target was overwritten" >&2; exit 1; }
# An unreadable baseline file never counts as unchanged.
echo '{"esp:a": "missing"}' > "$tmp/m.json"
if python3 -I vm/install-checksums.py compare "$tmp/m.json" "$tmp/m.json" >/dev/null; then
  echo "FAIL: missing==missing accepted" >&2; exit 1; fi
grep -q '^luks_passphrase=' "$tmp/out-erase-ok/preset.conf" || { echo "FAIL: preset lacks luks_passphrase" >&2; exit 1; }

echo "install-selftest ok"
