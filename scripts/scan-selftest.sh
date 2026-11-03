#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Self-tests for scripts/cve-scan.sh and scripts/secret-scan.sh (P5-8, #274). Fixtures are made here
# at run time: no advisory data and no secret-shaped string is committed. SKIP_SECRET_SCAN=1 skips
# the gitleaks part (it downloads the pinned binary).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- rpm version order (scripts/cve_scan.py evr_cmp) ---
python3 -I -B - <<'EOF' || fail "evr_cmp"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("c", "scripts/cve_scan.py")
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
cases = [  # (a, b, expected sign of a vs b), rpm's own test vectors
    ("1.0", "1.0", 0), ("1.0", "2.0", -1), ("2.0.1", "2.0", 1), ("2.0", "2.0.1", -1),
    ("5.5p1", "5.5p2", -1), ("5.5p10", "5.5p1", 1), ("10xyz", "10.1xyz", -1), ("xyz10", "xyz10.1", -1),
    ("1.0aa", "1.0a", 1), ("1.0a", "1.0aa", -1), ("10", "9", 1), ("1.010", "1.9", 1),
    ("1.05", "1.5", 0), ("1.0~rc1", "1.0", -1), ("1.0~rc1", "1.0~rc2", -1), ("1.0~rc1~git1", "1.0~rc1", -1),
    ("1.0^", "1.0", 1), ("1.0^git1", "1.0", 1), ("1.0^git1", "1.01", -1), ("1.0^git1~pre", "1.0^git1", -1),
    ("a", "1", -1), ("1", "a", 1), ("1.0.", "1.0", 0), ("2_0", "2.0", 0),
]
bad = [(a, b, e, c._segments_cmp(a, b)) for a, b, e in cases if c._segments_cmp(a, b) != e]
assert not bad, bad
assert c.evr_cmp(("1", "1.0", "1"), ("0", "9.0", "1")) == 1      # epoch first
assert c.evr_cmp(("0", "1.0", "2.fc44"), ("0", "1.0", "10.fc44")) == -1
EOF

# --- CVE scan fixtures ---
cat >"$tmp/updateinfo.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<updates>
  <update type="security"><id>FEDORA-2026-crit</id><severity>Critical</severity>
    <pkglist><collection>
      <package name="openssl-libs" epoch="1" version="3.5.1" release="2.fc44" arch="x86_64"/>
      <package name="openssl-libs" epoch="1" version="3.5.1" release="2.fc44" arch="aarch64"/>
    </collection></pkglist></update>
  <update type="security"><id>FEDORA-2026-imp</id><severity>Important</severity>
    <pkglist><collection>
      <package name="curl" epoch="0" version="8.15.0" release="1.fc44" arch="x86_64"/>
    </collection></pkglist></update>
  <update type="security"><id>FEDORA-2026-mod</id><severity>Moderate</severity>
    <pkglist><collection>
      <package name="vim-minimal" epoch="2" version="9.2.0" release="1.fc44" arch="x86_64"/>
    </collection></pkglist></update>
  <update type="bugfix"><id>FEDORA-2026-bug</id><severity>Critical</severity>
    <pkglist><collection>
      <package name="bash" epoch="0" version="5.3.9" release="1.fc44" arch="x86_64"/>
    </collection></pkglist></update>
  <update type="security"><id>FEDORA-2026-old</id><severity>Critical</severity>
    <pkglist><collection>
      <package name="glibc" epoch="0" version="2.42" release="1.fc44" arch="x86_64"/>
    </collection></pkglist></update>
</updates>
EOF
mkdir -p "$tmp/repo/build/arch/x86_64" "$tmp/repo/scripts" "$tmp/repo/security"
cp scripts/cve-scan.sh scripts/cve_scan.py "$tmp/repo/scripts/"
h=$(printf '%064d' 0)
cat >"$tmp/repo/build/arch/x86_64/packages.lock" <<EOF
# zeeos packages.lock v1 (ADR-0008). Test fixture.
# release=44
# arch=x86_64
openssl-libs 1:3.5.0-1.fc44.x86_64 $h openssl
curl 0:8.14.1-3.fc44.x86_64 $h curl
vim-minimal 2:9.1.0-1.fc44.x86_64 $h vim
bash 0:5.3.0-1.fc44.x86_64 $h bash
glibc 0:2.42-4.fc44.x86_64 $h glibc
EOF
scan() { # allowlist-file -> output, sets rc
  rc=0
  out=$(CVE_SCAN_TODAY=2026-10-26 CVE_ALLOWLIST="$1" bash "$tmp/repo/scripts/cve-scan.sh" x86_64 \
    --updateinfo "$tmp/updateinfo.xml" 2>&1) || rc=$?
}
allow() { printf -- '---\n%s\n' "$1" >"$tmp/allow.yaml"; echo "$tmp/allow.yaml"; }

# No allowlist: the Critical and Important fixes the lock lacks fail; Moderate, bugfix and an
# advisory whose fix is older than the lock don't count.
scan "$(allow '[]')"
[ "$rc" = 1 ] || fail "missing fixes: exit $rc: $out"
grep -q '^FAIL FEDORA-2026-crit Critical openssl-libs.x86_64 1:3.5.0-1.fc44 < 1:3.5.1-2.fc44$' <<<"$out" || fail "crit: $out"
grep -q '^FAIL FEDORA-2026-imp Important curl.x86_64' <<<"$out" || fail "imp: $out"
! grep -qE 'FEDORA-2026-(mod|bug|old)' <<<"$out" || fail "moderate/bugfix/old counted: $out"

# Both allowlisted with a reason and a future expiry: pass, still reported as ALLOWED.
scan "$(allow '- advisory: FEDORA-2026-crit
  package: openssl-libs
  reason: "test exception"
  expires: "2026-12-01"
- advisory: FEDORA-2026-imp
  package: curl
  reason: test exception
  expires: "2027-01-01"')"
[ "$rc" = 0 ] || fail "allowlisted: exit $rc: $out"
grep -q '^ALLOWED FEDORA-2026-crit' <<<"$out" || fail "allowed line: $out"

# Expired (from 00:00 UTC on the date), reason-less, unknown key, wrong package: fail.
for bad in '- advisory: FEDORA-2026-crit
  package: openssl-libs
  reason: r
  expires: "2026-10-26"' '- advisory: FEDORA-2026-crit
  package: openssl-libs
  expires: "2027-01-01"' '- advisory: FEDORA-2026-crit
  package: openssl-libs
  reason: r
  expires: "2027-01-01"
  skip: true' '- advisory: FEDORA-2026-crit
  package: openssl
  reason: r
  expires: "2027-01-01"' 'not: [a list]'; do
  scan "$(allow "$bad")"
  [ "$rc" = 1 ] || fail "bad allowlist accepted (exit $rc): $bad"
done

# Lock already has every fix: pass with no findings.
sed -i.bak -e 's/^openssl-libs 1:3.5.0-1/openssl-libs 1:3.5.1-2/' -e 's/^curl 0:8.14.1-3/curl 0:8.15.0-1/' \
  "$tmp/repo/build/arch/x86_64/packages.lock"
scan "$(allow '[]')"
[ "$rc" = 0 ] || fail "patched lock: exit $rc: $out"
grep -q ' 0 findings, ok$' <<<"$out" || fail "patched lock: $out"

# Bad input: exit 2.
rc=0; python3 -I scripts/cve_scan.py --updateinfo "$tmp/none.xml" "$tmp/repo/build/arch/x86_64/packages.lock" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "missing updateinfo: exit $rc"
# Unparsed or empty metadata must not pass as "0 findings" when advisories are required.
echo '<updates/>' >"$tmp/empty.xml"
rc=0; python3 -I scripts/cve_scan.py --updateinfo "$tmp/empty.xml" --min-advisories 1 --allowlist "$tmp/allow.yaml" \
  "$tmp/repo/build/arch/x86_64/packages.lock" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "empty updateinfo accepted: exit $rc"
echo "cve-scan selftest ok"

# --- secret scan ---
if [ "${SKIP_SECRET_SCAN:-0}" = 1 ]; then echo "secret-scan selftest SKIPPED"; exit 0; fi
r="$tmp/leak"; mkdir -p "$r"
git -C "$r" init -q; git -C "$r" config user.email t@example.invalid; git -C "$r" config user.name t
echo "clean" >"$r/README"; git -C "$r" add -A; git -C "$r" commit -qm clean
rc=0; bash scripts/secret-scan.sh "$r" >"$tmp/clean.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$tmp/clean.log" >&2; fail "clean repo: exit $rc"; }
# A GitHub-token-shaped string, generated now and only ever committed to this temp repo.
tok="ghp_$(python3 -I -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36)))')"
echo "token = \"$tok\"" >"$r/config.ini"; git -C "$r" add -A; git -C "$r" commit -qm leak
git -C "$r" rm -q config.ini; git -C "$r" commit -qm "remove it again"   # still in history
rc=0; bash scripts/secret-scan.sh "$r" >"$tmp/leak.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$tmp/leak.log" >&2; fail "planted token in history: exit $rc"; }
! grep -qF "$tok" "$tmp/leak.log" || fail "the finding was not redacted"
echo "secret-scan selftest ok"
