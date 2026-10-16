#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Dispatch within the model caps (docs/AUTOPILOT.md §1, §6): first `paused` issues
# oldest-first (they are further along), then `ready` issues (priority:high first, then
# oldest). With --resume only paused issues (resume.yml).
# Claude starts are staggered AUTOPILOT_STAGGER seconds apart (default 300, MISSION §11).
# Usage: scripts/autopilot/dispatch.sh [--resume]
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/autopilot/lib.sh
. "$here/lib.sh"

sources="paused ready"; [[ "${1:-}" == --resume ]] && sources=paused
stagger="${AUTOPILOT_STAGGER:-300}"

inflight() { # running agents of a model; paused / needs-human issues hold no slot
  gh issue list --repo "$REPO" --state open --label in-progress --limit 200 --json labels \
    --jq "[.[] | select(any(.labels[]; .name == \"model:$1\"))
           | select(all(.labels[]; .name != \"paused\" and .name != \"needs-human\"))] | length"
}
deps_closed() {
  local d
  for d in $(labels_of "$1" | sed -n 's/^blocked-by:#//p'); do
    [[ "$(gh issue view "$d" --repo "$REPO" --json state --jq .state)" == CLOSED ]] || return 1
  done
}

used_claude="$(inflight claude)"; used_codex="$(inflight codex)"; started_claude=0
for from in $sources; do
for n in $(gh issue list --repo "$REPO" --state open --label "$from" --limit 100 --json number,createdAt,labels \
    --jq 'map(select(all(.labels[]; .name != "needs-human")))
          | sort_by((if any(.labels[]; .name == "priority:high") then 0 else 1 end), .createdAt) | .[].number'); do
  model="$(issue_model "$n")"; agent="$(issue_agent "$n")"
  if [[ -z "$model" || -z "$agent" ]]; then log "#$n not dispatched: needs model:* and agent:* labels"; continue; fi
  if ! deps_closed "$n"; then log "#$n waits for its blocked-by issues"; continue; fi
  case "$model" in
    claude) (( used_claude < CAP_CLAUDE )) || continue ;;
    codex) (( used_codex < CAP_CODEX )) || continue ;;
    *) log "#$n unknown model '$model'"; continue ;;
  esac
  if [[ "$model" == claude ]] && (( started_claude > 0 )) && [[ -z "${DRY_RUN:-}" ]]; then sleep "$stagger"; fi
  w gh issue edit "$n" --repo "$REPO" --remove-label "$from" --add-label in-progress >/dev/null
  if ! w gh workflow run agent-dispatch.yml --repo "$REPO" -f issue="$n" -f mode=implement; then
    # Nothing started: give the slot back and leave the issue where it was.
    w gh issue edit "$n" --repo "$REPO" --remove-label in-progress --add-label "$from" >/dev/null || true
    log "#$n: dispatch failed; left $from"; continue
  fi
  log "dispatched #$n ($agent, $model)${from/ready/}"
  if [[ "$model" == claude ]]; then used_claude=$((used_claude + 1)); started_claude=$((started_claude + 1)); else used_codex=$((used_codex + 1)); fi
done
done
