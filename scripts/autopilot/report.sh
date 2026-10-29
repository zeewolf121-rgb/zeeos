#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Issues autopilot opens itself (docs/AUTOPILOT.md §1, §5, §8).
#   log-issue              print the pinned "Autopilot log" issue number, creating and pinning it once
#   nightly <run-id>       open (or update) the high-priority fix issue for a failed nightly-health run
#   release-rc             refuse automatic signing/publication; owner action required
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/autopilot/lib.sh
. "$here/lib.sh"

log_issue() {
  local n id
  n="$(gh issue list --repo "$REPO" --label autopilot-log --state open --json number --jq '.[0].number // empty')"
  if [[ -z "$n" ]]; then
    n="$(w gh issue create --repo "$REPO" --title "Autopilot log" --label autopilot-log \
      --body "One comment per autopilot run (orchestrator.yml). Kill switch: repo variable \`AUTOPILOT\`; see docs/AUTOPILOT.md." | sed 's#.*/##')"
    id="$(gh issue view "$n" --repo "$REPO" --json id --jq .id 2>/dev/null || true)"
    [[ -n "$id" ]] && w gh api graphql -f query="mutation{pinIssue(input:{issueId:\"$id\"}){issue{number}}}" >/dev/null
  fi
  echo "$n"
}

nightly() {
  local run="${1:?run-id}" url summary n
  url="https://github.com/$REPO/actions/runs/$run"
  summary="$("$here/../ci-summary.sh" "$run" "$REPO" 2>/dev/null || echo "(no summary)")"
  n="$(gh issue list --repo "$REPO" --label nightly-health --state open --json number --jq '.[0].number // empty')"
  if [[ -n "$n" ]]; then
    w gh issue comment "$n" --repo "$REPO" --body "Still failing: $url" >/dev/null; log "nightly still failing (#$n)"; return
  fi
  w gh issue create --repo "$REPO" --title "fix(ci): nightly health failure on main" \
    --label "ready,priority:high,nightly-health,agent:ci-engineer,model:claude,arch:both,parallel-safe" --body "## Goal
Nightly build + boot-test of \`main\` failed: $url. Find the cause and fix it, or open an issue for the owning agent and mark this one blocked-by it.

\`\`\`
$summary
\`\`\`

## Scope (directories)
\`/.github\`, \`/scripts\`; other directories through a new issue for their owner.

## Acceptance (CI evidence required)
- nightly-health green on main (link the run).

## Labels to set
ready, priority:high, nightly-health, agent:ci-engineer, model:claude

## Turn budget
medium 40" >/dev/null
  log "opened nightly-health fix issue"
}

release_rc() {
  # Signing and publishing are never autonomous. Keep the command as a safe
  # diagnostic for old callers; explicit owner release procedures remain separate.
  log "release candidate requires explicit owner action; no tag or release dispatched"
  return 1
}

case "${1:-}" in
  log-issue) log_issue ;;
  nightly) nightly "${2:-}" ;;
  release-rc) release_rc ;;
  *) echo "usage: report.sh log-issue|nightly <run-id>|release-rc" >&2; exit 2 ;;
esac
