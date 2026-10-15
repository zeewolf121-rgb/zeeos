#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Start Codex on a model:codex issue by posting an "@codex" task comment as the
# owner (CODEX_TOKEN). If Codex doesn't pick it up within CODEX_WAIT seconds,
# label the issue needs-human so the owner starts it from Codex cloud.
# Usage: scripts/codex-dispatch.sh <issue> [--dry-run]
# Env: GH_TOKEN (reads, labels), CODEX_TOKEN (mention; empty = fall back),
#      GITHUB_REPOSITORY (default: current repo), CODEX_WAIT (default 300),
#      CODEX_POLL (poll interval, default 20).
set -euo pipefail
issue="${1:?usage: codex-dispatch.sh <issue> [--dry-run]}"
dry="${2:-}"
repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
wait_s="${CODEX_WAIT:-300}"
bot='chatgpt-codex-connector'

title="$(gh issue view "$issue" --repo "$repo" --json title --jq .title)"
body="$(gh issue view "$issue" --repo "$repo" --json body --jq .body)"
agent="$(gh issue view "$issue" --repo "$repo" --json labels \
  --jq '[.labels[].name | select(startswith("agent:"))][0] // "" | ltrimstr("agent:")')"

fallback() {
  local msg="Codex did not pick up this issue ($1). Start it manually from Codex cloud with the task comment above (or this issue) as the prompt."
  if [[ "$dry" == --dry-run ]]; then echo "+ label needs-human: $msg"; return; fi
  gh issue edit "$issue" --repo "$repo" --add-label needs-human >/dev/null
  gh issue comment "$issue" --repo "$repo" --body "$msg" >/dev/null
  echo "needs-human: $1"
}

# Labels can arrive in any order; the run for the later label does the work.
[[ -n "$agent" ]] || { echo "no agent:* label yet; waiting for it"; exit 0; }
# Idempotent: both label events can reach here (runs are serialised per issue). A task
# comment newer than the last time the issue was resumed (paused removed) means Codex
# already has it; a resumed issue gets a fresh mention.
last_task="$(gh api --paginate "repos/$repo/issues/$issue/comments?per_page=100" \
  --jq '.[] | select(.body | startswith("@codex ")) | .created_at' | sort | tail -n1)"
last_resume="$(gh api --paginate "repos/$repo/issues/$issue/events?per_page=100" \
  --jq '.[] | select(.event == "unlabeled" and .label.name == "paused") | .created_at' | sort | tail -n1)"
if [[ -n "$last_task" && "$last_task" > "${last_resume:-0}" ]]; then
  echo "#$issue already has an @codex task comment; nothing to do"; exit 0
fi

# Task summary: the template sections before "## Labels to set", max 1500 chars.
# (Substring, not `| head -c`: an early-closing pipe SIGPIPEs sed under pipefail.)
summary="$(sed '/^## Labels to set/,$d' <<<"$body")"
summary="${summary:0:1500}"
slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-40)"
msg="@codex ${title}

${summary}

Act as **${agent}**: follow AGENTS.md and the \`${agent}\` section of docs/agent-roles-codex.md. Write only inside that role's directories (docs/agents.md). Work on branch \`agent/${agent}/${issue}-${slug}\`, keep the handoff in \`.agent/state/${issue}.md\`, and open a draft PR that says \`Closes #${issue}\`."

if [[ "$dry" == --dry-run ]]; then printf '+ comment on #%s:\n%s\n' "$issue" "$msg"; exit 0; fi
[[ -n "${CODEX_TOKEN:-}" ]] || { fallback "CODEX_TRIGGER_TOKEN not set"; exit 0; }

cid="$(GH_TOKEN="$CODEX_TOKEN" gh api "repos/$repo/issues/$issue/comments" -f body="$msg" --jq .id)"
echo "posted comment $cid; waiting up to ${wait_s}s for Codex"

# Picked up = the connector reacts (eyes/+1/rocket) or replies with a task link.
# A reply without a task link (e.g. "connect your account") counts as not picked up.
deadline=$(( SECONDS + wait_s ))
while (( SECONDS < deadline )); do
  sleep "${CODEX_POLL:-20}"
  if gh api "repos/$repo/issues/comments/$cid/reactions" \
      --jq ".[] | select(.user.login | startswith(\"$bot\")) | select(.content | IN(\"eyes\",\"+1\",\"rocket\")) | .id" | grep -q .; then
    echo "Codex picked up #$issue (reaction)"; exit 0
  fi
  replies="$(gh api --paginate "repos/$repo/issues/$issue/comments?per_page=100" \
    --jq ".[] | select(.id > $cid) | select(.user.login | startswith(\"$bot\")) | .body")"
  if grep -q '/codex/tasks/' <<<"$replies"; then echo "Codex picked up #$issue (task link)"; exit 0; fi
  if [[ -n "$replies" ]]; then fallback "Codex replied without starting a task"; exit 0; fi
done
fallback "no response within ${wait_s}s"
