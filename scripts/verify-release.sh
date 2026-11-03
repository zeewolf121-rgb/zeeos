#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Verify a ZeeOS release the way a user would (security/VERIFY.md, ADR-0007):
#   1. zeeos-ci.pub.minisig is a root-key signature over the trusted zeeos-ci.pub
#   2. SHA256SUMS.minisig is a CI-key signature over SHA256SUMS
#   3. sha256sum -c, and every zeeos-* payload file is listed in SHA256SUMS
# The keys come from the repo (security/keys, or KEYS_DIR), never from the download.
# The key files shipped in the release must be byte-identical to the trusted ones.
set -euo pipefail

if [[ ${1:-} == -h || $# -ne 1 ]]; then
  echo "Usage: verify-release.sh <dir|tag>   (a tag is fetched with: gh release download)" >&2
  [[ ${1:-} == -h ]] && exit 0
  exit 2
fi
keys=${KEYS_DIR:-"$(dirname "$0")/../security/keys"}
command -v minisign >/dev/null || { echo "ERROR: minisign not installed" >&2; exit 2; }

target=$1 tmp=""
trap '[[ -z $tmp ]] || rm -rf "$tmp"' EXIT
if [[ -d $target ]]; then
  dir=$target
else
  tmp=$(mktemp -d); dir=$tmp
  gh release download "$target" --dir "$dir" ${GH_REPO:+--repo "$GH_REPO"}
fi

fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

for f in SHA256SUMS SHA256SUMS.minisig zeeos-ci.pub zeeos-ci.pub.minisig zeeos-root.pub; do
  [[ -f $dir/$f ]] || bad "missing $dir/$f"
done
for f in zeeos-ci.pub zeeos-root.pub; do
  [[ -f $keys/$f ]] || bad "missing trusted key $keys/$f"
done
((fail == 0)) || exit 1

for k in zeeos-ci.pub zeeos-root.pub; do
  [[ $(sha256sum <"$dir/$k") == "$(sha256sum <"$keys/$k")" ]] || bad "$k in the release differs from the trusted $keys/$k"
done
minisign -Vm "$keys/zeeos-ci.pub" -x "$dir/zeeos-ci.pub.minisig" -p "$keys/zeeos-root.pub" >/dev/null \
  || bad "zeeos-ci.pub is not signed by the root key"
minisign -Vm "$dir/SHA256SUMS" -x "$dir/SHA256SUMS.minisig" -p "$keys/zeeos-ci.pub" >/dev/null \
  || bad "SHA256SUMS is not signed by the CI key"
((fail == 0)) || exit 1

(cd "$dir" && sha256sum -c SHA256SUMS) || bad "checksum mismatch"
shopt -s nullglob
for f in "$dir"/zeeos-*.iso "$dir"/zeeos-*.utm.zip; do
  grep -qF -- "  ${f##*/}" "$dir/SHA256SUMS" || bad "${f##*/} is not listed in SHA256SUMS"
done
((fail == 0)) || exit 1
echo "OK: $target verified (root -> CI key -> SHA256SUMS -> assets)"
