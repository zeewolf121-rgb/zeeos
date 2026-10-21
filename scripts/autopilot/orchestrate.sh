#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The deterministic half of one orchestrator run (docs/AUTOPILOT.md §1). Zero LLM tokens:
#   1. every open, non-draft PR: post gate statuses, merge it if all gates pass; then start
#      main's lint + merge-audit for autopilot merges that GitHub gave no push runs
#   2. label `ready` the current phase's startable issues; dispatch within the caps
#   3. phase 6 complete -> release candidate + manual gate
#   4. write a compact state report for the LLM step and key=value outputs
# Usage: scripts/autopilot/orchestrate.sh <state-report-file>   (outputs on stdout)
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/autopilot/lib.sh
. "$here/lib.sh"

report="${1:?usage: orchestrate.sh <state-report-file>}"
merge_err="$(mktemp)"; trap 'rm -f "$merge_err"' EXIT

{ # side effects only; stdout is reserved for the key=value status
for pr in $(gh pr list --repo "$REPO" --state open --limit 100 --json number,isDraft,labels \
    --jq '.[] | select((.isDraft | not) and all(.labels[]; .name != "needs-human")) | .number'); do
  "$here/gates.sh" status "$pr" || log "#$pr: status failed"
  # stdout names the gate that held the PR. Empty means gates.sh itself failed (e.g. GitHub
  # refused `gh pr merge`): log its last stderr line, not a bare "not merged" (#114).
  out="$("$here/gates.sh" merge "$pr" 2>"$merge_err")" \
    || log "${out:-#$pr not merged: $(tail -n1 "$merge_err")}"
done
"$here/gates.sh" push-workflows || log "push-workflows sweep failed"   # main's lint + merge-audit

"$here/phase.sh" mark-ready
"$here/dispatch.sh"   # paused issues first, then ready ones, one shared cap

status="$("$here/phase.sh" status)"
if grep -qx 'release_due=true' <<<"$status"; then "$here/report.sh" release-rc; fi
} >&2

{
  echo "# Autopilot state ($(date -u +%FT%TZ))"
  echo; echo '## Phase'; echo "$status"
  echo; echo '## Open issues (number, labels, title)'
  gh issue list --repo "$REPO" --state open --limit 100 --json number,title,labels,milestone \
    --jq '.[] | "#\(.number) [\([.labels[].name] | join(","))] (\(.milestone.title // "-")) \(.title)"'
  echo; echo '## Open PRs'
  gh pr list --repo "$REPO" --state open --limit 50 --json number,title,headRefName,isDraft \
    --jq '.[] | "#\(.number) \(.headRefName) draft=\(.isDraft) \(.title)"'
  echo; echo '## Handoffs (.agent/state/)'
  for f in .agent/state/*.md; do
    [[ "$(basename "$f")" == TEMPLATE.md ]] && continue
    echo "### $f"; head -n 20 "$f"
  done
  echo; echo '## Actions this run'
  cat "${AUTOPILOT_LOG:-/dev/null}" 2>/dev/null || true
} >"$report"

echo "$status"
