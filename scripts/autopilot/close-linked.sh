#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 ZeeOS contributors
# SPDX-License-Identifier: GPL-3.0-or-later
# Close the issues that recently merged PRs say they close ("Closes/Fixes/Resolves #N").
# GitHub ignores closing keywords on PRs merged with GITHUB_TOKEN, which is every autopilot
# merge, so linked issues stayed open and held up their dependents (#55, #96, #125, #128, #130).
# Only PRs merged into main count (a PR into another branch hasn't landed yet). Only open *issues*
# are closed, never PRs, and never an issue reopened after the PR merged:
# that's a deliberate "the fix wasn't enough" (e.g. #90). Run by orchestrate.sh before mark-ready.
# Usage: scripts/autopilot/close-linked.sh [how-many-recent-merged-PRs]
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/autopilot/lib.sh
. "$here/lib.sh"

limit="${1:-30}"
gh pr list --repo "$REPO" --state merged --base main --limit "$limit" --json number,mergedAt,body \
  --jq '.[] | "\(.number) \(.mergedAt) \((.body // "") | [scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?) #([0-9]+)")[]] | join(" "))"' \
  | while read -r pr merged nums; do
      for n in $nums; do
        st="$(gh api "repos/$REPO/issues/$n" --jq 'if .pull_request then "pr" else .state end' 2>/dev/null || true)"
        [[ "$st" == open ]] || continue
        reopened="$(gh api --paginate "repos/$REPO/issues/$n/events" \
          --jq '.[] | select(.event == "reopened") | .created_at' 2>/dev/null | sort | tail -n1)"
        if [[ -n "$reopened" && "$reopened" > "$merged" ]]; then
          log "#$n left open: reopened after #$pr merged"; continue
        fi
        w gh issue close "$n" --repo "$REPO" --comment "Closed by #$pr (merged by autopilot; GitHub doesn't apply closing keywords to merges made with GITHUB_TOKEN)." >/dev/null
        w gh issue edit "$n" --repo "$REPO" --remove-label in-progress,ready,paused >/dev/null 2>&1 || true
        log "#$n closed (linked from merged #$pr)"
      done
    done
