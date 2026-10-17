#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Publish the closure repo built by resolve.sh as a public OCI image and record its digest in
# packages.lock (ADR-0008). Runs on the host (needs podman); the push needs `podman login ghcr.io`
# (CI: GITHUB_TOKEN with packages: write). Ends with an ANONYMOUS pull: a private package fails here.
# Usage: build/pin/publish.sh <arch> [out-dir]
set -euo pipefail
arch="${1:?usage: publish.sh <arch> [out-dir]}"
# shellcheck source=build/pin/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
out="${2:-$PIN_ROOT/out/$arch}"
lock="$(pin_lock "$arch")"
if [[ "$(cat "$out/pin.status" 2>/dev/null)" == unchanged ]]; then
  echo "lock unchanged, nothing to publish"; exit 0
fi
[[ -f "$out/rpms/repodata/repomd.xml" ]] || { echo "no closure repo in $out/rpms: run resolve.sh first" >&2; exit 1; }
repo="ghcr.io/$PIN_OWNER/zeeos-closure-$arch"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp -a "$out/rpms" "$tmp/repo"
printf 'FROM scratch\nCOPY repo /repo\n' >"$tmp/Containerfile"
podman build -q -t "$repo:build" -f "$tmp/Containerfile" "$tmp"
podman push --digestfile "$tmp/digest" "$repo:build" "docker://$repo:lock-$(date -u +%Y%m%d%H%M%S)"
digest="$(<"$tmp/digest")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad digest: $digest" >&2; exit 1; }
sed -i "s|^# closure=.*|# closure=$repo@$digest|" "$lock"
# Anonymous pull check, with an empty auth file so no stored login can mask a private package.
auth="$(mktemp)"; echo '{}' >"$auth"
if ! podman pull -q --authfile "$auth" "$repo@$digest" >/dev/null; then
  rm -f "$auth"
  echo "::error::$repo is not anonymously pullable: the owner must make the GHCR package public (ADR-0008)" >&2
  exit 1
fi
rm -f "$auth"
echo "published $repo@$digest"
