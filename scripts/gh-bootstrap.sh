#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Idempotently creates labels (from .github/labels.yml) and the ZeeOS project board.
# Usage: scripts/gh-bootstrap.sh [--dry-run]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run() { if [[ "${1:-}" == --dry-run ]]; then shift; echo "+ $*"; else "$@"; fi; }
dry=""; [[ "${1:-}" == --dry-run ]] && dry=--dry-run
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
owner="${repo%%/*}"
grep -E '^- ' "$root/.github/labels.yml" | sed 's/^- //' | while IFS='|' read -r name color desc; do
  run $dry gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force
done
if ! gh project list --owner "$owner" --format json --jq '.projects[].title' 2>/dev/null | grep -qx 'ZeeOS'; then
  run $dry gh project create --owner "$owner" --title ZeeOS
fi
