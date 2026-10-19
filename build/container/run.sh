#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the pinned build container and run build/build-iso.sh inside it (privileged: loop devices).
# Usage: build/container/run.sh <arch> [out-dir]   (DRY_RUN=1 passes through)
set -euo pipefail
arch="${1:?usage: run.sh <arch> [out-dir]}"
out="${2:-}"
if [[ -n "$out" ]]; then
  # A custom out-dir must be new or empty: on Linux the whole dir is handed back to the
  # caller after a root build, so it must not contain anyone else's files (e.g. /tmp).
  if [[ -e "$out" && -n "$(ls -A "$out" 2>/dev/null)" ]]; then
    echo "out-dir $out must be new or empty" >&2; exit 2
  fi
  mkdir -p "$out" && out="$(cd "$out" && pwd)"
fi
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
engine_bin="$(command -v podman || command -v docker)" || { echo "need podman or docker" >&2; exit 2; }
engine=("$engine_bin")
# On Linux hosts without SELinux (e.g. GitHub's Ubuntu runners), kiwi's SELinux relabel
# (setfiles) can only store security.selinux labels with real CAP_SYS_ADMIN on the host.
# A rootless container lacks that even with --privileged, so run the engine as root.
# Build and run must use the same (root) image store. Afterwards, hand back what the build
# created: the checkout's out/ (ours) and the custom out-dir (new or empty at start).
if [[ "$(uname -s)" == Linux && "$(id -u)" != 0 ]]; then
  engine=(sudo "$engine_bin")
  hand_back() {
    sudo chown -hR "$(id -u):$(id -g)" "$root/out" ${out:+"$out"} 2>/dev/null || true
  }
  trap hand_back EXIT
fi
# Tools (ADR-0008): use the digest-pinned per-arch image once published; else build locally, unpinned.
# shellcheck source=build/arch/x86_64/tools-image.lock
source "$root/build/arch/$arch/tools-image.lock"
if [[ -n "${TOOLS_IMAGE:-}" && "${ZEEOS_LOCAL_TOOLS:-0}" != 1 ]]; then
  "${engine[@]}" pull -q "$TOOLS_IMAGE" >/dev/null
  tag="$TOOLS_IMAGE"
# Opt-in cache hooks for the local build (the tag pins only the base image, not the
# Containerfile, so reuse is never the default):
#   ZEEOS_REUSE_BUILD_IMAGE=1  skip the build if $tag already exists (e.g. after docker load)
#   ZEEOS_BUILD_CACHE_FROM=ref pass --cache-from ref to the build
elif [[ "${ZEEOS_REUSE_BUILD_IMAGE:-0}" == 1 ]] && "${engine[@]}" image inspect "$tag" >/dev/null 2>&1; then
  echo "build container $tag already present; skipping container build (ZEEOS_REUSE_BUILD_IMAGE=1)"
else
  echo "::warning::build tools are NOT pinned (no TOOLS_IMAGE in build/arch/$arch/tools-image.lock, or ZEEOS_LOCAL_TOOLS=1): building the Containerfile locally" >&2
  build_args=(--build-arg "BASE_IMAGE=$base" -t "$tag" -f "$dir/Containerfile")
  [[ -z "${ZEEOS_BUILD_CACHE_FROM:-}" ]] || build_args+=(--cache-from "$ZEEOS_BUILD_CACHE_FROM")
  "${engine[@]}" build "${build_args[@]}" "$dir"
fi
epoch="${SOURCE_DATE_EPOCH:-$(git -C "$root" log -1 --format=%ct)}"
args=("$arch")
mounts=(-v "$root:/work")
# ZEEOS_KIWI_CACHE: absolute host dir kept between runs as kiwi's package cache.
if [[ -n "${ZEEOS_KIWI_CACHE:-}" ]]; then
  [[ "$ZEEOS_KIWI_CACHE" == /* ]] || { echo "ZEEOS_KIWI_CACHE must be an absolute path" >&2; exit 2; }
  mkdir -p "$ZEEOS_KIWI_CACHE"
  mounts+=(-v "$ZEEOS_KIWI_CACHE:/var/cache/kiwi")
fi
# A custom out dir outside the checkout must be mounted too, at the same absolute path,
# or build-iso.sh writes into the container's own filesystem and --rm discards it.
if [[ -n "$out" ]]; then
  case "$out/" in
    "$root"/*) args+=("/work${out#"$root"}") ;;      # inside the checkout: same dir under /work
    *) args+=("$out"); mounts+=(-v "$out:$out") ;;  # elsewhere: mount at the same path
  esac
fi
# Package closure (ADR-0008): pulled on the host (podman login lives there) and mounted read-only.
# ZEEOS_CLOSURE_REBUILD=1 instead lets the container rebuild it from the lock (writable mount).
envs=()
if [[ "${ZEEOS_UNPINNED:-0}" != 1 && "${DRY_RUN:-0}" != 1 ]]; then
  closure="$root/out/closure-$arch"
  if [[ "${ZEEOS_CLOSURE_REBUILD:-0}" == 1 ]]; then
    rm -rf "$closure"; mkdir -p "$closure"; mounts+=(-v "$closure:/closure")
  else
    "$root/build/pin/pull.sh" "$arch" "$closure"; mounts+=(-v "$closure:/closure:ro")
  fi
  envs+=(-e ZEEOS_CLOSURE_DIR=/closure)
fi
# ZEEOS_ENTRY lets `make pin-packages` run build/pin/resolve.sh in the same container.
entry="${ZEEOS_ENTRY:-build/build-iso.sh}"
# Inside the container we are root, so build-iso.sh skips sudo (ZEEOS_IN_CONTAINER).
"${engine[@]}" run --rm --privileged \
  "${mounts[@]}" -w /work "${envs[@]}" \
  -e SOURCE_DATE_EPOCH="$epoch" -e DRY_RUN="${DRY_RUN:-0}" -e ZEEOS_IN_CONTAINER=1 \
  -e ZEEOS_UNPINNED="${ZEEOS_UNPINNED:-0}" -e ZEEOS_CLOSURE_REBUILD="${ZEEOS_CLOSURE_REBUILD:-0}" \
  "$tag" bash -c 'git config --global --add safe.directory /work && exec "$@"' _ "$entry" "${args[@]}"
