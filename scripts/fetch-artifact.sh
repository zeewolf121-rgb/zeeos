#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Download one artifact of a workflow run as parallel byte ranges, verify its sha256 digest, unzip it.
# Azure blob storage throttles each connection (seen on the self-hosted aarch64 runners: ~0.1 MB/s
# per connection, full line speed with 8 in parallel), so actions/download-artifact's single stream
# can take hours for a 1 GB ISO. boot-test.yml falls back to download-artifact if this fails.
# On self-hosted runners the verified zip is cached by its digest in FETCH_CACHE_DIR, so the two
# aarch64 boot jobs on the same Mac share one download instead of splitting the line between two.
# Needs curl, jq, unzip and a token with actions:read. Bash 3.2 compatible (macOS runners).
# Usage: scripts/fetch-artifact.sh <run-id> <artifact-name> <dest-dir>
#   env: GH_TOKEN, GITHUB_REPOSITORY; FETCH_JOBS (default 8), FETCH_CHUNK_MB (default 32),
#        FETCH_CACHE_DIR (default ~/.cache/zeeos-artifacts when RUNNER_ENVIRONMENT=self-hosted; empty = off)
set -euo pipefail

if [[ "${1:-}" == --part ]]; then   # internal: --part <url> <start> <end> <file>
  curl -fsS --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 20 --speed-time 60 --speed-limit 10000 \
    -r "$3-$4" -o "$5" "$2"
  exit 0
fi

run="${1:?usage: fetch-artifact.sh <run-id> <name> <dest>}" name="${2:?name}" dest="${3:?dest}"
repo="${GITHUB_REPOSITORY:?}" token="${GH_TOKEN:?}"
jobs="${FETCH_JOBS:-8}" chunk=$(( ${FETCH_CHUNK_MB:-32} * 1024 * 1024 ))
api="https://api.github.com/repos/$repo/actions"
auth=(-H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json")

meta="$(curl -fsS "${auth[@]}" "$api/runs/$run/artifacts?name=$name")"
id="$(jq -r '.artifacts[0].id // empty' <<<"$meta")"
size="$(jq -r '.artifacts[0].size_in_bytes // empty' <<<"$meta")"
digest="$(jq -r '.artifacts[0].digest // empty' <<<"$meta")"
[[ -n "$id" && -n "$size" ]] || { echo "artifact $name not found in run $run" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
n=$(( (size + chunk - 1) / chunk ))
start_s=$SECONDS

sha256() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }
# download <zip>: parallel ranges into <zip>, then size and digest checks.
download() {
  # The zip endpoint redirects to a short-lived signed blob URL; ranges go straight to the blob.
  local url i s e got
  url="$(curl -fsS -o /dev/null -w '%{redirect_url}' "${auth[@]}" "$api/artifacts/$id/zip")"
  [[ "$url" == https://* ]] || { echo "no download URL for artifact $id" >&2; return 1; }
  rm -f "$tmp"/part.*
  for (( i = 0; i < n; i++ )); do
    s=$(( i * chunk )); e=$(( s + chunk - 1 )); (( e < size )) || e=$(( size - 1 ))
    printf '%s %s %s %s\n' "$url" "$s" "$e" "$tmp/part.$(printf '%05d' "$i")"
  done | xargs -P "$jobs" -n 4 bash "$0" --part
  cat "$tmp"/part.* >"$1"; rm -f "$tmp"/part.*
  got="$(wc -c <"$1" | tr -d ' ')"
  [[ "$got" == "$size" ]] || { echo "size mismatch: got $got, expected $size" >&2; return 1; }
  if [[ -n "$digest" && "sha256:$(sha256 "$1")" != "$digest" ]]; then echo "digest mismatch for $name" >&2; return 1; fi
}

cache=""
if [[ -n "$digest" && "${RUNNER_ENVIRONMENT:-}" == self-hosted ]]; then cache="${FETCH_CACHE_DIR-$HOME/.cache/zeeos-artifacts}"; fi
how="downloaded"
zip="$tmp/a.zip"
if [[ -n "$cache" ]]; then
  how="from cache"
  mkdir -p "$cache"
  key="$cache/${digest#sha256:}"
  # First job takes the lock (mkdir is atomic) and downloads; the others wait for the finished file.
  # A lock older than 20 min is stale (its job died): take it over. Waiting is capped at 15 min.
  w=0
  while (( w < 180 )) && [[ ! -f "$key.zip" ]]; do
    w=$(( w + 1 ))
    if mkdir "$key.lock" 2>/dev/null; then
      if download "$tmp/a.zip"; then how="downloaded, cached"; mv "$tmp/a.zip" "$key.zip.part" && mv "$key.zip.part" "$key.zip"; fi
      rmdir "$key.lock"; break
    fi
    if [[ -n "$(find "$key.lock" -maxdepth 0 -mmin +20 2>/dev/null)" ]]; then rmdir "$key.lock" 2>/dev/null || true; continue; fi
    if (( w == 1 )); then echo "another job is downloading $name; waiting for it"; fi
    sleep 5
  done
  if [[ -f "$key.zip" && "sha256:$(sha256 "$key.zip")" == "$digest" ]]; then
    zip="$key.zip"
    # Keep the 4 newest artifacts.
    find "$cache" -maxdepth 1 -name '*.zip' -print0 | xargs -0 ls -t 2>/dev/null | tail -n +5 | while read -r old; do rm -f "$old"; done
  else
    how="downloaded"; zip="$tmp/a.zip"; download "$zip"
  fi
else
  download "$zip"
fi
mkdir -p "$dest"
unzip -q -o "$zip" -d "$dest"
echo "fetched $name ($size bytes, $n parts, ${jobs}x parallel, $how) in $(( SECONDS - start_s ))s${digest:+, digest verified}"
