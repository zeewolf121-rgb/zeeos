#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Owner-run, once: protect main and enable auto-merge (docs/AUTOPILOT.md §3).
# Needs GitHub Pro (or a public repo) for a private repo; prints the API error otherwise.
# Required approvals stay 0: PRs from local sessions are authored by the owner, who can't
# approve their own PR. Owner approval of hard stops is the required `owner-gate` status.
# Usage: scripts/autopilot/protect-main.sh [--dry-run]
set -euo pipefail
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
body='{
  "required_status_checks": {"strict": true,
    "contexts": ["lint", "build-iso", "boot-test", "cross-review", "owner-gate"]},
  "enforce_admins": true,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null,
  "required_conversation_resolution": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}'
if [[ "${1:-}" == --dry-run ]]; then printf 'PUT repos/%s/branches/main/protection\n%s\n' "$repo" "$body"; exit 0; fi
gh api -X PUT "repos/$repo/branches/main/protection" --input - <<<"$body" >/dev/null
gh api -X PATCH "repos/$repo" -F allow_auto_merge=true -F delete_branch_on_merge=true >/dev/null
echo "main protected; auto-merge on"
