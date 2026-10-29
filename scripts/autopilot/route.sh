#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Work out how to run an issue: prints model=, agent=, turns=, llm= lines (for $GITHUB_OUTPUT)
# and marks the issue in-progress. Turn cap = the issue's budget (small 15 / medium 40 /
# large 80, MISSION §11); model tier = the agent's frontmatter, opus for installer-disk.
# --from-label: started by a label event; skip (empty model) if the issue is already
# in-progress, so two label events on one issue don't start two agents (runs are serialised).
# Usage: scripts/autopilot/route.sh <issue> [--from-label]
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/autopilot/lib.sh
. "$here/lib.sh"

# Review-only jobs have their own route in agent-dispatch; implementations stop here.
if codex_controller; then echo "model="; echo "agent="; exit 0; fi

n="${1:?usage: route.sh <issue> [--from-label]}"
model="$(issue_model "$n")"; agent="$(issue_agent "$n")"
if [[ "${2:-}" == --from-label ]]; then
  # A label event only queues the issue. dispatch.sh (orchestrator) starts agents in dependency
  # order and within the caps; creating twelve labelled issues used to start twelve agents,
  # blocked ones included (Phase 3, 2026-10-20).
  if [[ -n "$model" && -n "$agent" ]] && ! has_label "$n" in-progress \
      && ! has_label "$n" needs-human && ! has_label "$n" ready; then
    w gh issue edit "$n" --repo "$REPO" --add-label ready >/dev/null
    log "#$n queued (ready) for dispatch.sh"
  fi
  model=""
fi
budget="$(gh issue view "$n" --repo "$REPO" --json body --jq .body \
  | sed -n '/^## Turn budget/,$p' | grep -oE 'small|medium|large' | head -n1 || true)"
case "$budget" in small) turns=15 ;; large) turns=80 ;; *) turns=40 ;; esac
# Codex agents have no .claude/agents file; under pipefail a missing file must not abort.
tier="$(sed -n 's/^model: *//p' ".claude/agents/$agent.md" 2>/dev/null | head -n1 || true)"
if has_label "$n" installer-disk; then tier=opus; fi
case "${tier:-sonnet}" in
  opus) llm=claude-opus-5-5 ;; haiku) llm=claude-haiku-5-5 ;; *) llm=claude-sonnet-5-5 ;;
esac
if [[ -n "$model" && -n "$agent" ]]; then
  w gh issue edit "$n" --repo "$REPO" --remove-label ready --add-label in-progress >/dev/null
fi
printf 'issue=%s\nmodel=%s\nagent=%s\nturns=%s\nllm=%s\n' "$n" "$model" "$agent" "$turns" "$llm"
