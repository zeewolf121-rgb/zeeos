#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Download one artifact of a workflow run as parallel byte ranges, verify its sha256 digest, unzip it.
# Azure blob storage throttles each connection (seen on the self-hosted aarch64 runners: ~0.1 MB/s
# per connection, full line speed with 8 in parallel), so actions/download-artifact's single stream
# can take hours for a 1 GB ISO. boot-test.yml falls back to download-artifact if this fails.
# Needs curl, jq, unzip and a token with actions:read. Bash 3.2 compatible (macOS runners).
# Usage: scripts/fetch-artifact.sh <run-id> <artifact-name> <dest-dir>
#   env: GH_TOKEN, GITHUB_REPOSITORY; FETCH_JOBS (default 8), FETCH_CHUNK_MB (default 32)
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
# The zip endpoint redirects to a short-lived signed blob URL; ranges go straight to the blob.
url="$(curl -fsS -o /dev/null -w '%{redirect_url}' "${auth[@]}" "$api/artifacts/$id/zip")"
[[ "$url" == https://* ]] || { echo "no download URL for artifact $id" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
n=$(( (size + chunk - 1) / chunk ))
start_s=$SECONDS
for (( i = 0; i < n; i++ )); do
  s=$(( i * chunk )); e=$(( s + chunk - 1 )); (( e < size )) || e=$(( size - 1 ))
  printf '%s %s %s %s\n' "$url" "$s" "$e" "$tmp/part.$(printf '%05d' "$i")"
done | xargs -P "$jobs" -n 4 bash "$0" --part

cat "$tmp"/part.* >"$tmp/a.zip"
got="$(wc -c <"$tmp/a.zip" | tr -d ' ')"
[[ "$got" == "$size" ]] || { echo "size mismatch: got $got, expected $size" >&2; exit 1; }
if [[ -n "$digest" ]]; then
  sum="$( (sha256sum "$tmp/a.zip" 2>/dev/null || shasum -a 256 "$tmp/a.zip") | cut -d' ' -f1)"
  [[ "sha256:$sum" == "$digest" ]] || { echo "digest mismatch: sha256:$sum != $digest" >&2; exit 1; }
fi
mkdir -p "$dest"
unzip -q -o "$tmp/a.zip" -d "$dest"
echo "fetched $name ($size bytes, $n parts, ${jobs}x parallel) in $(( SECONDS - start_s ))s${digest:+, digest verified}"
