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
fail() { echo "FAIL: $*" >&2; exit 1; }

# blank: a 64 KiB disk with no pre-existing partitions. win: a 4 MiB GPT disk (ESP, MSR, Windows) whose
# seed.json records the GPT identity, built by tests/gpt-fixture.py.
mkdir -p "$tmp/blank"
python3 -I - "$tmp/blank" <<'EOF'
import json, os, sys
d = sys.argv[1]
with open(os.path.join(d, "disk.img"), "wb") as f:
    f.write(bytes(range(256)) * 256)
json.dump({"case": "t", "size": 65536, "partitions": [], "files": {}}, open(os.path.join(d, "seed.json"), "w"))
EOF
python3 -I tests/gpt-fixture.py make "$tmp/win"
win_off=$((4096 * 512))  # first byte of the Windows partition

# run <name> <case> <seed> <install fixture> <installed fixture> <expect pass|fail> [junit pattern...]
run() {
  local name=$1 case=$2 sd=$3 fi=$4 fd=$5 want=$6 o rc=0; shift 6
  o=$tmp/out-$name
  FAKE_SERIAL_INSTALL=$fx/$fi FAKE_SERIAL_INSTALLED=$fx/$fd FAKE_POWEROFF=1 QEMU_BIN=$tmp/qemu \
    FW_CODE=$tmp/code.fd FW_VARS=$tmp/vars.fd ISO=$tmp/fake.iso SEED_DIR=$sd OUT=$o ARCH=x86_64 CASE=$case \
    INSTALL_TIMEOUT=10 BOOT_TIMEOUT=10 vm/install-test.sh >"$o.log" 2>&1 || rc=$?
  if { [ "$want" = pass ] && [ "$rc" != 0 ]; } || { [ "$want" = fail ] && [ "$rc" = 0 ]; }; then
    cat "$o.log" >&2; fail "$name expected $want, exit $rc"
  fi
  for pat in "$@"; do
    grep -q -- "$pat" "$o/junit.xml" || { cat "$o/junit.xml" >&2; fail "$name: junit lacks '$pat'"; }
  done
}

run erase-ok erase "$tmp/blank" serial-install-done.log serial-installed-ok.log pass \
  'failures="0"' 'name="install.x86_64.erase.bootmenu"' 'name="install.x86_64.erase.rootfs"'
run erase-install-fail erase "$tmp/blank" serial-install-fail.log serial-installed-ok.log fail 'partition: no space'
run luks-skips-boot luks "$tmp/blank" serial-install-done.log serial-installed-ok.log pass \
  'skipped="1"' 'LUKS passphrase entry at boot not implemented'
run refuse-ok refuse-bitlocker "$tmp/win" serial-install-refused.log serial-installed-ok.log pass \
  'failures="0"' 'name="install.x86_64.refuse-bitlocker.checksums"' 'Windows Boot Manager NVRAM check'
FAKE_FLIP=$((win_off + 100)) run refuse-disk-changed refuse-bitlocker "$tmp/win" serial-install-refused.log \
  serial-installed-ok.log fail 'pre-existing partitions changed'
run refuse-but-installed refuse-hibernated "$tmp/win" serial-install-done.log serial-installed-ok.log fail \
  'installed although the case must be refused'
run alongside-no-windows-entry alongside "$tmp/win" serial-install-done.log serial-installed-ok.log fail \
  'want zeeos=1 windows=1'
run alongside-ok alongside "$tmp/win" serial-install-done.log serial-installed-windows.log pass 'failures="0"' \
  'name="install.x86_64.alongside.layout"'
FAKE_FLIP=512 run refuse-gpt-changed refuse-bitlocker "$tmp/win" serial-install-refused.log \
  serial-installed-ok.log fail 'gpt-primary'
run installed-without-secureboot erase "$tmp/blank" serial-install-done.log serial-installed-nosb.log fail \
  'Secure Boot unreported, want enabled'
[ -s "$tmp/out-refuse-ok/checksums-partitions-before.json" ] || fail "no partition checksums"

# Alongside: the post-install GPT is checked, not just bytes at the seed's offsets. Shrinking Windows
# and adding ZeeOS is allowed; deleting, retyping, moving or growing a retained partition, an
# invalid or inconsistent GPT, and a truncated disk are not.
FAKE_GPT=shrink run alongside-shrink-ok alongside "$tmp/win" serial-install-done.log serial-installed-windows.log \
  pass 'failures="0"'
for c in 'delete-msr:msr: deleted' 'type-esp:esp: type changed' 'move-esp:esp: moved' \
         'grow-windows:windows: grew' 'corrupt-backup:backup GPT header CRC mismatch' \
         'mismatch:primary and backup GPT differ' 'truncate:truncated or resized'; do
  FAKE_GPT=${c%%:*} run "alongside-${c%%:*}" alongside "$tmp/win" serial-install-done.log \
    serial-installed-windows.log fail 'name="install.x86_64.alongside.layout"><failure' "${c#*:}"
done
python3 -I vm/install-checksums.py "$tmp/win/disk.img" "$tmp/win/seed.json" layout >/dev/null || fail "pristine GPT rejected"
python3 -I - "$tmp/win/seed.json" "$tmp/nogpt.json" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1])); del s["gpt"]; json.dump(s, open(sys.argv[2], "w"))
EOF
if python3 -I vm/install-checksums.py "$tmp/win/disk.img" "$tmp/nogpt.json" layout >/dev/null; then
  fail "layout accepted a seed without a GPT record"; fi

# A symlinked seed target is refused before anything is written through it, by the seeder (in both
# modes) and by the harness (also when it would copy SEED_DIR, and in dry-run).
mkdir -p "$tmp/sym"; echo precious > "$tmp/victim"; ln -s "$tmp/victim" "$tmp/sym/disk.img"
if python3 -I vm/install-seed.py erase "$tmp/sym" 2>/dev/null; then fail "symlinked disk.img accepted"; fi
if python3 -I vm/install-seed.py --dry-run erase "$tmp/sym" 2>/dev/null; then fail "symlinked disk.img accepted (dry-run)"; fi
for dry in 0 1; do
  if DRY_RUN=$dry QEMU_BIN=$tmp/qemu FW_CODE=$tmp/code.fd FW_VARS=$tmp/vars.fd ISO=$tmp/fake.iso SEED_DIR=$tmp/blank \
      OUT=$tmp/sym CASE=erase vm/install-test.sh >/dev/null 2>&1; then fail "harness accepted symlinked disk.img (DRY_RUN=$dry)"; fi
done
[ "$(cat "$tmp/victim")" = precious ] || fail "symlink target was overwritten"

# Dry-run writes nothing, for every case: no OUT is created, and an existing OUT (old results and
# all) is left byte for byte, through the harness and through the seeder directly.
snap() {
  python3 -I - "$1" <<'EOF'
import hashlib, os, sys
for root, dirs, files in sorted(os.walk(sys.argv[1])):
    for n in sorted(dirs + files):
        p = os.path.join(root, n); st = os.lstat(p)
        h = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.isfile(p) else "-"
        print(p, st.st_mode, st.st_size, st.st_mtime_ns, h)
EOF
}
mkdir -p "$tmp/old"; cp "$tmp/win/disk.img" "$tmp/win/seed.json" "$tmp/old/"; echo old > "$tmp/old/serial-install.log"
echo '{}' > "$tmp/old/junit.xml"; before=$(snap "$tmp/old")
for c in erase luks alongside refuse-bitlocker refuse-hibernated; do
  for o in "$tmp/dry-$c" "$tmp/old"; do
    DRY_RUN=1 QEMU_BIN=$tmp/qemu FW_CODE=$tmp/code.fd FW_VARS=$tmp/vars.fd ISO=$tmp/fake.iso OUT=$o ARCH=x86_64 \
      CASE=$c vm/install-test.sh >"$tmp/dry.log" 2>&1 || { cat "$tmp/dry.log" >&2; fail "dry-run $c failed"; }
    grep -q "dry-run: $c: .* steps planned, nothing written" "$tmp/dry.log" || { cat "$tmp/dry.log" >&2; fail "dry-run $c: no seed plan"; }
    python3 -I vm/install-seed.py --dry-run "$c" "$o" >/dev/null 2>"$tmp/dry.log" || fail "seed dry-run $c failed"
    grep -q 'create sparse .*disk.img' "$tmp/dry.log" || fail "seed dry-run $c: plan lacks the disk"
  done
  [ ! -e "$tmp/dry-$c" ] || fail "dry-run $c created OUT"
  case $c in erase|luks) ;; *) grep -q 'sgdisk --zap-all' "$tmp/dry.log" || fail "seed dry-run $c: plan lacks the GPT";; esac
done
[ "$(snap "$tmp/old")" = "$before" ] || fail "dry-run changed an existing OUT"

# An unreadable baseline file never counts as unchanged.
echo '{"esp:a": "missing"}' > "$tmp/m.json"
if python3 -I vm/install-checksums.py compare "$tmp/m.json" "$tmp/m.json" >/dev/null; then fail "missing==missing accepted"; fi
grep -q '^luks_passphrase=' "$tmp/out-erase-ok/preset.conf" || fail "preset lacks luks_passphrase"

echo "install-selftest ok"
