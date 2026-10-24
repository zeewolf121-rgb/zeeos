#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fixture tests for the ZeeOS-rebuild half of the closure (ADR-0011): the sha256 fail-closed check that
# runs before kiwi, the lock's origin column, the repo block, and the spec delta. Needs no network,
# containers or rpm tools; it does NOT build any RPM (that needs the tools image, see build/README.md).
# Usage: build/tests/zeeos-closure-test.sh
# shellcheck disable=SC2015  # "A && ok || bad": ok and bad always succeed
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=build/pin/lib.sh
source "$root/build/pin/lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
# expect <pass|fail> <name> <command...>
expect() {
  local want="$1" name="$2"; shift 2
  if "$@" >"$tmp/out" 2>&1; then got=pass; else got=fail; fi
  if [[ "$got" == "$want" ]]; then ok "$name"; else bad "$name (wanted $want)"; sed 's/^/     /' "$tmp/out"; fi
}
has_msg() { grep -q "$1" "$tmp/out"; }

# --- fixture: a closure dir with two ZeeOS binaries and their SRPM -----------------------------
mkfix() {   # mkfix <dir>: writes <dir>/zeeos/*.rpm and <dir>/packages.lock
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/zeeos"
  printf 'calamares-bytes' >"$d/zeeos/calamares-3.3.14-5.zeeos1.fc44.x86_64.rpm"
  printf 'libs-bytes' >"$d/zeeos/calamares-libs-3.3.14-5.zeeos1.fc44.x86_64.rpm"
  printf 'srpm-bytes' >"$d/zeeos/calamares-3.3.14-5.zeeos1.fc44.src.rpm"
  {
    echo "# zeeos packages.lock v1 fixture"
    echo "bash 0:5.3-1.fc44.x86_64 $(printf 'x%.0s' {1..64}) bash"
    echo "calamares 0:3.3.14-5.zeeos1.fc44.x86_64 $(sha256sum "$d/zeeos/calamares-3.3.14-5.zeeos1.fc44.x86_64.rpm" | cut -d' ' -f1) calamares zeeos-rebuild"
    echo "calamares-libs 0:3.3.14-5.zeeos1.fc44.x86_64 $(sha256sum "$d/zeeos/calamares-libs-3.3.14-5.zeeos1.fc44.x86_64.rpm" | cut -d' ' -f1) calamares zeeos-rebuild"
    echo "calamares 0:3.3.14-5.zeeos1.fc44.src $(sha256sum "$d/zeeos/calamares-3.3.14-5.zeeos1.fc44.src.rpm" | cut -d' ' -f1) calamares zeeos-rebuild-src"
  } >"$d/packages.lock"
}
fx="$tmp/fx"
verify() { pin_verify_zeeos "$fx/packages.lock" "$fx/zeeos" "$@"; }

mkfix "$fx"
expect pass "intact zeeos/ matches the lock" verify
expect pass "lock helpers: 3 zeeos lines, 1 Fedora line" bash -c "
  source '$root/build/pin/lib.sh'
  [[ \$(pin_lock_lines '$fx/packages.lock' zeeos-rebuild | wc -l) == 2 && \$(pin_lock_lines '$fx/packages.lock' zeeos-rebuild-src | wc -l) == 1 &&
     \$(pin_lock_lines '$fx/packages.lock' fedora | wc -l) == 1 ]]"
expect pass "SRPM line is not an installable identity" bash -c "
  source '$root/build/pin/lib.sh'
  [[ \$(pin_lock_identities '$fx/packages.lock' | wc -l) == 3 ]] && ! pin_lock_identities '$fx/packages.lock' | grep -q '\.src'"
expect pass "pin_lock_has_zeeos: true for the fixture" pin_lock_has_zeeos "$fx/packages.lock"

mkfix "$fx"; printf 'tampered' >"$fx/zeeos/calamares-3.3.14-5.zeeos1.fc44.x86_64.rpm"
expect fail "tampered RPM is rejected" verify
has_msg "does not match the lock" && ok "  ... and says why" || bad "  ... message"
expect pass "tampered RPM passes identity-only (explicit rebuild mode)" verify identity-only

mkfix "$fx"; rm "$fx/zeeos/calamares-libs-3.3.14-5.zeeos1.fc44.x86_64.rpm"
expect fail "missing locked RPM is rejected" verify
has_msg "missing calamares-libs" && ok "  ... and names it" || bad "  ... message"
expect fail "missing locked RPM is rejected even in identity-only mode" verify identity-only

mkfix "$fx"; printf 'extra' >"$fx/zeeos/sddm-0.21.0-13.zeeos1.fc44.x86_64.rpm"
expect fail "unlocked RPM in zeeos/ is rejected" verify
has_msg "sddm-0.21.0-13.zeeos1.fc44.x86_64.rpm is not in the lock" && ok "  ... and names it" || bad "  ... message"

mkfix "$fx"; rm "$fx/zeeos/calamares-3.3.14-5.zeeos1.fc44.src.rpm"
expect fail "missing SRPM is rejected (sources ship with the binaries)" verify

# Mixed Fedora/ZeeOS closures.
mkfix "$fx"; echo "calamares 0:3.3.14-5.fc44.x86_64 $(printf 'a%.0s' {1..64}) calamares" >>"$fx/packages.lock"
expect fail "same package locked as both Fedora and zeeos-rebuild is rejected" verify
has_msg "both as a Fedora" && ok "  ... and says why" || bad "  ... message"

mkfix "$fx"
sed -i 's/^calamares-libs 0:3.3.14-5.zeeos1.fc44.x86_64/calamares-libs 0:3.3.14-5.fc44.x86_64/' "$fx/packages.lock"
expect fail "zeeos-rebuild line without the .zeeos release marker is rejected" verify
has_msg "no .zeeos release marker" && ok "  ... and says why" || bad "  ... message"

mkfix "$fx"
expect pass "a Fedora-only closure with no zeeos/ dir has no zeeos lines" bash -c "
  source '$root/build/pin/lib.sh'
  grep -v zeeos '$fx/packages.lock' >'$tmp/fed.lock'
  ! pin_lock_has_zeeos '$tmp/fed.lock'"
expect pass "Fedora lines (no origin column) stay Fedora" bash -c "
  source '$root/build/pin/lib.sh'
  grep -v zeeos '$fx/packages.lock' >'$tmp/fed.lock'
  [[ \$(pin_lock_lines '$tmp/fed.lock' fedora | wc -l) == 1 ]]"
# An empty zeeos/ dir against a lock that names ZeeOS RPMs must fail, not pass vacuously.
mkdir -p "$tmp/empty"
expect fail "empty zeeos/ dir against a zeeos lock fails" pin_verify_zeeos "$fx/packages.lock" "$tmp/empty"
# ... and unlocked RPMs against a Fedora-only lock too.
grep -v zeeos "$fx/packages.lock" >"$tmp/fed.lock"
expect fail "zeeos RPMs present but the lock names none is rejected" pin_verify_zeeos "$tmp/fed.lock" "$fx/zeeos"

# --- kiwi repo block: second repo unsigned, Fedora repo keeps gpgcheck ---------------------------
cp "$root/build/arch/x86_64/repos-pinned.xml" "$tmp/repos.xml"
sed -i 's|@CLOSURE_DIR@|/c|' "$tmp/repos.xml"
pin_inject_zeeos_repo "$tmp/repos.xml" /c/zeeos
expect pass "repos.xml: closure repo keeps package_gpgcheck=true" grep -q 'alias="zeeos-closure" package_gpgcheck="true"' "$tmp/repos.xml"
expect pass "repos.xml: zeeos-rebuild repo is unsigned and points at zeeos/" bash -c "
  grep -q 'alias=\"zeeos-rebuild\".*package_gpgcheck=\"false\"' '$tmp/repos.xml' && grep -q 'dir:///c/zeeos' '$tmp/repos.xml'"
expect pass "repos.xml: still well-formed XML with two repositories" bash -c "
  python3 -I -c 'import sys,xml.dom.minidom as m; d=m.parse(sys.argv[1]); sys.exit(0 if len(d.getElementsByTagName(\"repository\"))==2 else 1)' '$tmp/repos.xml'"
cp "$root/build/arch/aarch64/repos-pinned.xml" "$tmp/repos2.xml"
pin_inject_zeeos_repo "$tmp/repos2.xml" ""
expect pass "repos.xml without ZeeOS RPMs: no zeeos-rebuild repo, no leftover placeholder" bash -c "
  ! grep -q 'zeeos-rebuild\|@ZEEOS_REPO@' '$tmp/repos2.xml'"
expect pass "installed-system rule: no repo shipped in overlays uses package_gpgcheck=false" bash -c "
  ! grep -rIl 'package_gpgcheck=.false' '$root/desktop' '$root/build/common' '$root/build/arch/x86_64/root' '$root/build/arch/aarch64/root' 2>/dev/null | grep -q ."

# --- source.lock gate: never builds on a guessed or missing hash ---------------------------------
arch="$(uname -m)"
expect fail "build.sh refuses an empty SRPM_SHA256" bash "$root/build/rpms/build.sh" "$arch" "$tmp/o"
has_msg "BLOCKED" && ok "  ... reports it as blocked" || bad "  ... message"
expect pass "calamares source.lock names a real NEVRA, shared by both arches" bash -c "
  grep -q '^SRPM=calamares-3.3.14-5.fc44.src.rpm\$' '$root/build/rpms/calamares/source.lock' && [[ ! -e '$root/build/arch/x86_64/rpms' ]]"

# --- spec delta ---------------------------------------------------------------------------------
cat >"$tmp/calamares.spec" <<'EOF'
Name:           calamares
Release:        5%{?dist}
Requires:       grub2
Requires:       setxkbmap
%ifarch x86_64
Requires:       grub2-efi-x64
%endif
EOF
expect pass "spec delta applies to a calamares-shaped spec" bash "$root/build/rpms/spec-delta.sh" calamares "$tmp/calamares.spec"
expect pass "  ... setxkbmap gone, release marked, other Requires kept" bash -c "
  ! grep -q setxkbmap '$tmp/calamares.spec' && grep -q '^Release:        5.zeeos1%{?dist}\$' '$tmp/calamares.spec' &&
  grep -q 'Requires:       grub2\$' '$tmp/calamares.spec' && grep -q 'grub2-efi-x64' '$tmp/calamares.spec'"
expect fail "spec delta fails when Fedora already dropped the Requires (delta no longer applies)" bash "$root/build/rpms/spec-delta.sh" calamares "$tmp/calamares.spec"
printf 'Release: 5%%{?dist}\nRequires: setxkbmap\nRequires: setxkbmap\n' >"$tmp/dup.spec"
expect fail "spec delta fails on an ambiguous spec" bash "$root/build/rpms/spec-delta.sh" calamares "$tmp/dup.spec"
expect fail "spec delta rejects an unknown package" bash "$root/build/rpms/spec-delta.sh" nosuch "$tmp/calamares.spec"

echo "$pass passed, $fail failed"
[[ "$fail" == 0 ]]
