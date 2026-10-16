#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Resolve the current digest of the Fedora base image tag and write it to base-image.lock.
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build/container/base-image.lock
source "$dir/base-image.lock"
digest="$(skopeo inspect --format '{{.Digest}}' "docker://$BASE_IMAGE_REF:$BASE_IMAGE_TAG")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad digest: $digest" >&2; exit 1; }
sed -i "s|^BASE_IMAGE_DIGEST=.*|BASE_IMAGE_DIGEST=$digest|" "$dir/base-image.lock"
echo "pinned $BASE_IMAGE_REF:$BASE_IMAGE_TAG@$digest"
