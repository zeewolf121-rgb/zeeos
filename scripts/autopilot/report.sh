#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Issues autopilot opens itself (docs/AUTOPILOT.md §1, §5, §8).
#   log-issue              print the pinned "Autopilot log" issue number, creating and pinning it once
#   nightly <run-id>       open (or update) the high-priority fix issue for a failed nightly-health run
#   release-rc             tag the next v<VERSION>-rc.N on main, start release.yml, open the manual gate
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/autopilot/lib.sh
. "$here/lib.sh"

version="${RELEASE_VERSION:-1.0.0}"

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
  local last n tag sha
  if gh issue list --repo "$REPO" --label manual-gate --state open --json number --jq '.[].number' | grep -q .; then
    log "manual gate already open; no new rc"; return
  fi
  last="$(gh api --paginate "repos/$REPO/git/matching-refs/tags/v$version-rc." --jq '.[].ref' \
    | sed -n "s#^refs/tags/v$version-rc\.\([0-9]*\)\$#\1#p" | sort -n | tail -n1)"
  n=$(( ${last:-0} + 1 )); tag="v$version-rc.$n"
  sha="$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha)"
  w gh api "repos/$REPO/git/refs" -f ref="refs/tags/$tag" -f sha="$sha" >/dev/null
  w gh workflow run release.yml --repo "$REPO" --ref "$tag" -f tag="$tag"
  w gh issue create --repo "$REPO" --title "Manual gate: $tag" --assignee "$OWNER" \
    --label "manual-gate,decision,phase:6" --body "Pre-release **$tag** (main @ ${sha:0:7}) is building in release.yml.
Run the manual gate (MISSION §14), then tick each box. Only you tag the final \`v$version\` (hard stop).

- [ ] Real Windows 11 PC, Secure Boot on, BitLocker suspended: dual boot works and Windows Update still works
- [ ] UTM on Apple Silicon: ISO install + UTM bundle
- [ ] VirtualBox/VMware on Windows: x86_64 install
- [ ] USB via Rufus and Etcher: boots
- [ ] Release notes, SHA256SUMS.minisig and install guides checked" >/dev/null
  log "tagged $tag, started release.yml, opened the manual gate"
}

case "${1:-}" in
  log-issue) log_issue ;;
  nightly) nightly "${2:-}" ;;
  release-rc) release_rc ;;
  *) echo "usage: report.sh log-issue|nightly <run-id>|release-rc" >&2; exit 2 ;;
esac
