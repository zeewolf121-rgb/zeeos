#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 ZeeOS contributors
# PreToolUse hook (Bash): stop Claude sessions from merging PRs or pushing to main.
# GitHub branch protection isn't available on this plan, so this is the guard.
# Only the owner merges (GitHub UI); autopilot merges via scripts/autopilot/gates.sh,
# which checks CI, cross-review and owner-gate itself.
set -euo pipefail

input="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
cwd="$(jq -r '.cwd // empty' <<<"$input")"
ws='[[:space:]]'
pattern="gh${ws}+pr${ws}+merge|pulls/[0-9]+/merge|mergePullRequest|enablePullRequestAutoMerge"
pattern+="|git${ws}+push${ws}.*(${ws}|:|\+)(refs/heads/)?main(${ws}|$)"
# A bare `git push` (or `git push origin`) on main updates main without naming it,
# so while the session's checkout is on main, deny every push.
if [[ "$(git -C "${cwd:-.}" symbolic-ref --short -q HEAD 2>/dev/null || true)" == main ]]; then
  pattern+="|git${ws}+push(${ws}|$)"
fi

if printf '%s' "$cmd" | grep -Eq -- "$pattern"; then
  jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
    permissionDecisionReason: "ZeeOS rule: Claude sessions never merge PRs or push to main. Branch protection is unavailable, so this hook enforces it. Ask the owner to merge in the GitHub UI, or let autopilot merge via scripts/autopilot/gates.sh merge <pr>."}}'
fi
exit 0
