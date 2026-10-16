#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the pinned build container and run build/build-iso.sh inside it (privileged: loop devices).
# Usage: build/container/run.sh <arch> [out-dir]   (DRY_RUN=1 passes through)
set -euo pipefail
arch="${1:?usage: run.sh <arch> [out-dir]}"
out="${2:-}"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$dir/../.." && pwd)"
# shellcheck source=build/container/base-image.lock
source "$dir/base-image.lock"
if [[ -n "$BASE_IMAGE_DIGEST" ]]; then
  base="$BASE_IMAGE_REF@$BASE_IMAGE_DIGEST"
  tag="zeeos-build:${BASE_IMAGE_DIGEST:7:12}"
else
  base="$BASE_IMAGE_REF:$BASE_IMAGE_TAG"
  tag="zeeos-build:$BASE_IMAGE_TAG-unpinned"
  echo "::warning::build container base image is NOT digest-pinned; run 'make pin-container'" >&2
fi
engine="$(command -v podman || command -v docker)" || { echo "need podman or docker" >&2; exit 2; }
"$engine" build --build-arg "BASE_IMAGE=$base" -t "$tag" -f "$dir/Containerfile" "$dir"
epoch="${SOURCE_DATE_EPOCH:-$(git -C "$root" log -1 --format=%ct)}"
args=("$arch")
[[ -n "$out" ]] && args+=("$out")
# Inside the container we are root, so build-iso.sh skips sudo (ZEEOS_IN_CONTAINER).
"$engine" run --rm --privileged \
  -v "$root:/work" -w /work \
  -e SOURCE_DATE_EPOCH="$epoch" -e DRY_RUN="${DRY_RUN:-0}" -e ZEEOS_IN_CONTAINER=1 \
  -e ZEEOS_SNAPSHOT_URL="${ZEEOS_SNAPSHOT_URL:-}" \
  "$tag" bash -c 'git config --global --add safe.directory /work && exec build/build-iso.sh "$@"' _ "${args[@]}"
