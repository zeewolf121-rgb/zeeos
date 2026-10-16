#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Phase bookkeeping from milestones "Phase N: …" (docs/AUTOPILOT.md §1, §8).
#   status         key=value lines: current, opened, prev_exit, plan_open, untriaged, needs_llm, release_due
#   mark-ready     label `ready` the current phase's open issues that aren't started and have no open deps
#   mark-opened N  record in milestone N's description that its issues have been opened
# A phase is complete when its milestone is [opened], has issues, and none are open
# (planning issues labelled phase-plan don't count). Current = lowest incomplete phase.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/autopilot/lib.sh
. "$here/lib.sh"

ms_json="$(gh api --paginate "repos/$REPO/milestones?state=all&per_page=100")"
ms_field() { jq -r --arg p "Phase $1:" "[.[] | select(.title | startswith(\$p))][0].$2 // \"\"" <<<"$ms_json"; }
issues_in() { # phase -> "number state labels,..." per issue (excluding PRs and phase-plan)
  local t; t="$(ms_field "$1" title)"; [[ -n "$t" ]] || return 0
  gh issue list --repo "$REPO" --milestone "$t" --state all --limit 300 --json number,state,labels \
    --jq '.[] | "\(.number) \(.state) \([.labels[].name] | join(","))"' | grep -v 'phase-plan' || true
}
complete() { # phase
  local rows
  [[ "$(ms_field "$1" description)" == *"[opened]"* ]] || return 1
  rows="$(issues_in "$1")"
  [[ -n "$rows" ]] && ! grep -q ' OPEN ' <<<"$rows"
}
current() { local n; for n in 1 2 3 4 5 6 7; do complete "$n" || { echo "$n"; return; }; done; echo 8; }
nightly_ok() { # the latest nightly's `health` job itself passed (skipped jobs also read as success)
  local id
  id="$(gh run list --repo "$REPO" --workflow nightly-health.yml --branch main --limit 1 \
    --json databaseId --jq '.[0].databaseId // ""')"
  [[ -n "$id" ]] || return 1
  [[ "$(gh api "repos/$REPO/actions/runs/$id/jobs" --jq '.jobs[] | select(.name == "health") | .conclusion')" == success ]]
}

status() {
  local cur opened=false prev=true plan=false untriaged=0 llm=false release=false gate
  cur="$(current)"
  if (( cur <= 7 )) && [[ "$(ms_field "$cur" description)" == *"[opened]"* ]]; then opened=true; fi
  if (( cur > 1 )) && ! nightly_ok; then prev=false; fi
  if (( cur <= 7 )) && gh issue list --repo "$REPO" --milestone "$(ms_field "$cur" title)" --state open \
      --label phase-plan --json number --jq '.[].number' | grep -q .; then plan=true; fi
  if (( cur <= 7 )); then
    untriaged="$(issues_in "$cur" | awk '$2 == "OPEN" && ($3 !~ /model:/ || $3 !~ /agent:/)' | wc -l | tr -d ' ')"
  fi
  # Phase 6 done -> release candidate + manual gate (hard stop). Phase 7 opens only after the
  # owner closes the manual gate and tags v1.0.0.
  gate="$(gh issue list --repo "$REPO" --label manual-gate --state all --limit 1 --json state --jq '.[0].state // ""')"
  if (( cur == 7 )) && [[ -z "$gate" ]] && [[ "$prev" == true ]]; then release=true; fi
  if (( cur <= 7 )) && [[ "$opened" == false && "$plan" == false && "$prev" == true ]]; then
    if (( cur < 7 )) || { [[ "$gate" == CLOSED ]] && gh api "repos/$REPO/git/ref/tags/v1.0.0" >/dev/null 2>&1; }; then
      llm=true
    fi
  fi
  if (( untriaged > 0 )); then llm=true; fi
  printf 'current=%s\nopened=%s\nprev_exit=%s\nplan_open=%s\nuntriaged=%s\nneeds_llm=%s\nrelease_due=%s\n' \
    "$cur" "$opened" "$prev" "$plan" "$untriaged" "$llm" "$release"
}

mark_ready() {
  local cur n st labels d ok
  cur="$(current)"; (( cur <= 7 )) || return 0
  [[ "$(ms_field "$cur" description)" == *"[opened]"* ]] || return 0
  while read -r n st labels; do
    [[ "$st" == OPEN ]] || continue
    [[ ",$labels," =~ ,(ready|in-progress|paused|needs-human), ]] && continue
    [[ "$labels" == *model:* && "$labels" == *agent:* ]] || continue
    ok=true
    for d in $(tr ',' '\n' <<<"$labels" | sed -n 's/^blocked-by:#//p'); do
      [[ "$(gh issue view "$d" --repo "$REPO" --json state --jq .state)" == CLOSED ]] || ok=false
    done
    if [[ "$ok" == true ]]; then w gh issue edit "$n" --repo "$REPO" --add-label ready >/dev/null; log "#$n ready"; fi
  done < <(issues_in "$cur")
}

mark_opened() {
  local n="${1:?phase}" num desc
  num="$(ms_field "$n" number)"; desc="$(ms_field "$n" description)"
  [[ -n "$num" ]] || { echo "no milestone for phase $n" >&2; return 1; }
  [[ "$desc" == *"[opened]"* ]] && return 0
  w gh api -X PATCH "repos/$REPO/milestones/$num" -f description="${desc:+$desc }[opened]" >/dev/null
  log "phase $n marked opened"
}

case "${1:-status}" in
  status) status ;;
  mark-ready) mark_ready ;;
  mark-opened) mark_opened "${2:-}" ;;
  *) echo "usage: phase.sh status|mark-ready|mark-opened N" >&2; exit 2 ;;
esac
