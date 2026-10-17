#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the build container for THIS host's arch natively, push it to GHCR and pin it (ADR-0008):
# writes build/arch/<arch>/tools-image.lock (digest) and tools.lock (rpm -qa). Needs `podman login ghcr.io`
# (CI: GITHUB_TOKEN with packages: write); ends with an anonymous pull, which fails for private packages.
# Usage: build/container/publish.sh <arch>   (<arch> must match the host: no emulation)
set -euo pipefail
arch="${1:?usage: publish.sh <arch>}"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$dir/../.." && pwd)"
[[ "$(uname -m | sed 's/arm64/aarch64/')" == "$arch" ]] || { echo "publish natively: host is $(uname -m), not $arch" >&2; exit 2; }
# shellcheck source=build/container/base-image.lock
source "$dir/base-image.lock"
[[ -n "$BASE_IMAGE_DIGEST" ]] || { echo "pin the base image first: make pin-container" >&2; exit 1; }
repo="ghcr.io/${ZEEOS_REGISTRY_OWNER:-zeewolf121-rgb}/zeeos-build"
podman build --build-arg "BASE_IMAGE=$BASE_IMAGE_REF@$BASE_IMAGE_DIGEST" -t "$repo:build-$arch" -f "$dir/Containerfile" "$dir"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
podman push --digestfile "$tmp/digest" "$repo:build-$arch" "docker://$repo:$arch-$(date -u +%Y%m%d%H%M%S)"
digest="$(<"$tmp/digest")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad digest: $digest" >&2; exit 1; }
echo '{}' >"$tmp/auth"
podman pull -q --authfile "$tmp/auth" "$repo@$digest" >/dev/null \
  || { echo "::error::$repo is not anonymously pullable: the owner must make the GHCR package public (ADR-0008)" >&2; exit 1; }
lock="$root/build/arch/$arch"
{
  echo "# SPDX-License-""Identifier: GPL-3.0-or-later"
  echo "# Digest-pinned build container for $arch (ADR-0008). Written by build/container/publish.sh."
  echo "TOOLS_IMAGE=$repo@$digest"
} >"$lock/tools-image.lock"
{
  echo "# SPDX-License-""Identifier: GPL-3.0-or-later"
  echo "# rpm -qa of the published build container for $arch (written by build/container/publish.sh)."
  podman run --rm "$repo@$digest" rpm -qa --qf '%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' | LC_ALL=C sort
} >"$lock/tools.lock"
echo "published $repo@$digest"
