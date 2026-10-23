# shellcheck shell=bash disable=SC2034  # constants are used by the scripts that source this
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared helpers for scripts/autopilot/*. Source it; don't run it.
# Env: GITHUB_REPOSITORY, DRY_RUN (non-empty = print writes instead of doing them),
#      AUTOPILOT_LOG (file that collects one line per action for the run summary).
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
OWNER="${REPO%%/*}"
CAP_CLAUDE="${AUTOPILOT_CAP_CLAUDE:-3}"   # MISSION §11: 3 Claude + 1 Codex
CAP_CODEX="${AUTOPILOT_CAP_CODEX:-1}"
CODEX_BOT='chatgpt-codex-connector'      # login prefix (REST adds "[bot]")
CLAUDE_BOT='claude'

# Hard stops (docs/AUTOPILOT.md §7): autopilot never merges these; the owner does.
# installer-disk is no longer a hard stop (owner, 2026-10-19, #70): it merges on Opus authoring +
# cross-review like other PRs. Kept as a list so a label can be made a hard stop again.
HARD_STOP_LABELS="${AUTOPILOT_HARD_STOP_LABELS-}"
HARD_STOP_PATHS='^(\.github/workflows/|scripts/autopilot/|security/keys/)|(^|/)[^/]*(secret|minisign)[^/]*$|\.(key|pem|minisig)$'

log() {
  printf '%s\n' "$*" >&2
  if [[ -n "${AUTOPILOT_LOG:-}" ]]; then printf -- '- %s\n' "$*" >>"$AUTOPILOT_LOG"; fi
}
# Run a write action, or just log it under DRY_RUN.
w() { if [[ -n "${DRY_RUN:-}" ]]; then log "DRY: $*"; else "$@"; fi; }

# The merge guards themselves are hard stops too (owner decision, 2026-10-17): the hook that
# stops Claude sessions merging (.claude/) and the audit that flags unguarded merges.
HARD_STOP_PATHS+='|^(\.claude/|scripts/merge-audit\.sh$)'

labels_of() { gh issue view "$1" --repo "$REPO" --json labels --jq '.labels[].name'; }
has_label() { labels_of "$1" | grep -qxF "$2"; }
issue_model() { labels_of "$1" | sed -n 's/^model://p' | head -n1; }
issue_agent() { labels_of "$1" | sed -n 's/^agent://p' | head -n1; }

# The issue a PR implements: from agent/<agent>/<N>-… or "Closes #N" (empty if none).
linked_issue() {
  local s
  s="$(gh pr view "$1" --repo "$REPO" --json headRefName,body --jq '"\(.headRefName) \(.body)"')"
  if [[ "$s" =~ ^agent/[^/]+/([0-9]+)- || "$s" =~ [Cc]loses\ \#([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; fi
}

# Which model wrote a PR: claude | codex | human | fork | unknown.
# "fork" = the head branch lives in another repository. The repo is public, so anyone can
# open one and name the branch agent/orchestrator/* or write "Closes #N"; autopilot never
# reviews, dispatches for, or merges those. The owner handles them by hand.
pr_model() {
  local pr="$1" cross ref num m=""
  read -r cross ref < <(gh pr view "$pr" --repo "$REPO" --json isCrossRepository,headRefName \
    --jq '"\(.isCrossRepository) \(.headRefName)"')
  if [[ "$cross" != false ]]; then echo fork; return; fi
  case "$ref" in
    agent/orchestrator/*) echo claude; return ;;
    codex/*) echo codex; return ;;
    human/*) echo human; return ;;
  esac
  num="$(linked_issue "$pr")"
  if [[ -n "$num" ]]; then m="$(issue_model "$num")"; fi
  echo "${m:-unknown}"
}

pr_head() { gh pr view "$1" --repo "$REPO" --json headRefOid --jq .headRefOid; }
