#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Self-test of scripts/release-assets.sh, verify-release.sh and release-notes.sh.
# Makes a throwaway root + CI key pair in a temp dir (never committed, never MINISIGN_*).
# Needs minisign; without it the signing cases are reported as SKIPPED, not passed.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass() { echo "ok: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }
expect_fail() { local what=$1; shift; if "$@" >"$tmp/o" 2>&1; then cat "$tmp/o" >&2; die "$what unexpectedly succeeded"; fi; pass "$what"; }

# Fixtures: small fake assets.
mkdir "$tmp/in"
printf 'x86 iso\n' >"$tmp/in/kiwi-out.x86_64.iso"
printf 'arm iso\n' >"$tmp/in/kiwi-out.aarch64.iso"
printf 'utm zip\n' >"$tmp/in/zeeos.aarch64.utm.zip"

# release-notes.sh against the committed public keys and a fixture changelog.
cat >"$tmp/CHANGELOG.md" <<'EOF'
# Changelog
## [0.6.0] - 2026-12-01
- NEWER-ENTRY
## v0.5.0-rc.10
- RC10-ENTRY
## [0.5.0-rc.1] - 2026-11-01
- first candidate
### Added
- thing
## [0.4.0] - 2026-10-01
- OLDER-ENTRY
EOF
scripts/release-notes.sh v0.5.0-rc.1 -c "$tmp/CHANGELOG.md" >"$tmp/notes.md"
grep -q 'first candidate' "$tmp/notes.md" || die "notes lack the changelog section"
grep -q -- '- thing' "$tmp/notes.md" || die "notes lack the subsection"
if grep -q -e NEWER-ENTRY -e OLDER-ENTRY -e RC10-ENTRY "$tmp/notes.md"; then die "notes include other versions (rc.10 for rc.1?)"; fi
for s in 'sha256sum -c' 'shasum -a 256' 'Get-FileHash' 'minisign -Vm SHA256SUMS -p zeeos-ci.pub'; do
  grep -qF -- "$s" "$tmp/notes.md" || die "notes lack '$s'"
done
for k in security/keys/zeeos-ci.pub security/keys/zeeos-root.pub; do
  grep -qF "$(sed -n 's/^untrusted comment: minisign public key //p' "$k")" "$tmp/notes.md" || die "notes lack key id of $k"
done
scripts/release-notes.sh v9.9.9 -c "$tmp/CHANGELOG.md" | grep -q 'No CHANGELOG.md entry' || die "missing section not reported"
pass "release-notes.sh"

# release-assets.sh: dry run writes nothing; naming; checksums; size limit.
scripts/release-assets.sh -n -v 0.5.0-rc.1 -o "$tmp/dry" "$tmp"/in/* >"$tmp/o"
[[ ! -e $tmp/dry ]] || die "dry run wrote files"
pass "release-assets.sh dry run"
scripts/release-assets.sh -v 0.5.0-rc.1 -o "$tmp/rel" "$tmp"/in/* >/dev/null
for n in zeeos-0.5.0-rc.1-x86_64.iso zeeos-0.5.0-rc.1-aarch64.iso zeeos-0.5.0-rc.1-aarch64.utm.zip \
         SHA256SUMS zeeos-ci.pub zeeos-ci.pub.minisig zeeos-root.pub; do
  [[ -f $tmp/rel/$n ]] || die "missing staged $n"
done
(cd "$tmp/rel" && sha256sum -c SHA256SUMS >/dev/null) || die "staged SHA256SUMS does not verify"
pass "release-assets.sh naming and SHA256SUMS"
truncate -s 2G "$tmp/big.x86_64.iso"   # exactly 2 GiB, sparse
expect_fail "oversize asset (2 GiB) rejected" scripts/release-assets.sh -v 0.5.0 -o "$tmp/big" "$tmp/big.x86_64.iso"
[[ ! -e $tmp/big ]] || die "oversize run created the output dir"
ln -s "$tmp/big.x86_64.iso" "$tmp/link.x86_64.iso"   # the size gate measures the target, not the link
expect_fail "oversize asset behind a symlink rejected" scripts/release-assets.sh -n -v 0.5.0 -o "$tmp/big" "$tmp/link.x86_64.iso"
truncate -s 1G "$tmp/ok.x86_64.iso"
scripts/release-assets.sh -n -v 0.5.0 -o "$tmp/big" "$tmp/ok.x86_64.iso" >/dev/null || die "1 GiB asset rejected"
expect_fail "unclassifiable file rejected" scripts/release-assets.sh -v 0.5.0 -o "$tmp/x" "$tmp/CHANGELOG.md"
expect_fail "bad version rejected" scripts/release-assets.sh -v latest -o "$tmp/x" "$tmp/in/kiwi-out.x86_64.iso"

# verify-release.sh needs minisign.
if ! command -v minisign >/dev/null; then
  echo "SKIPPED: minisign not installed; verify-release.sh good/tampered/wrong-key cases not run"
  exit 0
fi
mk() { # <name>: throwaway unencrypted key pair in $tmp/keys-<name>
  mkdir -p "$tmp/k-$1"
  minisign -G -W -f -p "$tmp/k-$1/pub" -s "$tmp/k-$1/sec" >/dev/null
}
mk root; mk ci; mk evil
trusted=$tmp/trusted; mkdir "$trusted"
cp "$tmp/k-root/pub" "$trusted/zeeos-root.pub"
cp "$tmp/k-ci/pub" "$trusted/zeeos-ci.pub"
minisign -S -s "$tmp/k-root/sec" -m "$trusted/zeeos-ci.pub" -t "test ci key" >/dev/null   # -> zeeos-ci.pub.minisig

# build <dir> <signing-secret-key>: stage a release with the throwaway keys and sign SHA256SUMS.
build() {
  KEYS_DIR=$trusted scripts/release-assets.sh -v 0.5.0-rc.1 -o "$1" "$tmp"/in/* >/dev/null
  cp "$trusted/zeeos-ci.pub.minisig" "$1/"
  minisign -S -s "$2" -m "$1/SHA256SUMS" -t "test" >/dev/null
}
verify() { KEYS_DIR=${KEYS:-$trusted} scripts/verify-release.sh "$1"; }

build "$tmp/good" "$tmp/k-ci/sec"
verify "$tmp/good" >/dev/null || die "good release failed to verify"
pass "good release verifies"

cp -r "$tmp/good" "$tmp/tamper"; printf 'evil' >>"$tmp/tamper/zeeos-0.5.0-rc.1-x86_64.iso"
expect_fail "tampered ISO fails" verify "$tmp/tamper"

build "$tmp/wrongsig" "$tmp/k-evil/sec"
expect_fail "SHA256SUMS signed by the wrong key fails" verify "$tmp/wrongsig"

# The verifier trusts a different CI key than the one that signed (e.g. a swapped key file).
mkdir "$tmp/trusted2"; cp "$tmp/k-root/pub" "$tmp/trusted2/zeeos-root.pub"; cp "$tmp/k-evil/pub" "$tmp/trusted2/zeeos-ci.pub"
KEYS=$tmp/trusted2 expect_fail "wrong trusted CI key fails" verify "$tmp/good"

# CI key not signed by the trusted root.
mkdir "$tmp/trusted3"; cp "$tmp/k-evil/pub" "$tmp/trusted3/zeeos-root.pub"; cp "$trusted/zeeos-ci.pub" "$tmp/trusted3/"
KEYS=$tmp/trusted3 expect_fail "CI key not signed by the root fails" verify "$tmp/good"

cp -r "$tmp/good" "$tmp/swapped"; cp "$tmp/k-evil/pub" "$tmp/swapped/zeeos-ci.pub"
expect_fail "swapped zeeos-ci.pub in the release fails" verify "$tmp/swapped"

cp -r "$tmp/good" "$tmp/unlisted"; echo x >"$tmp/unlisted/zeeos-0.5.0-rc.1-extra.iso"
expect_fail "asset missing from SHA256SUMS fails" verify "$tmp/unlisted"

cp -r "$tmp/good" "$tmp/nosig"; rm "$tmp/nosig/SHA256SUMS.minisig"
expect_fail "missing signature fails" verify "$tmp/nosig"

# The committed public keys form a valid chain (public data only).
minisign -Vm security/keys/zeeos-ci.pub -x security/keys/zeeos-ci.pub.minisig -p security/keys/zeeos-root.pub >/dev/null \
  || die "committed zeeos-ci.pub is not signed by the committed root key"
pass "committed key chain verifies"
echo "release-selftest: all passed"
