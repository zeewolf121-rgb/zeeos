#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Summarise a failed GitHub Actions run in under 2 KB: failed step, first error,
# and 40 lines of context. Agents read this instead of raw logs (MISSION §11).
# Usage: scripts/ci-summary.sh <run-id> [repo]
set -euo pipefail
run="${1:?usage: ci-summary.sh <run-id> [owner/repo]}"
repo_arg=(); [[ -n "${2:-}" ]] && repo_arg=(--repo "$2")
log="$(gh run view "$run" ${repo_arg[@]+"${repo_arg[@]}"} --log-failed 2>/dev/null || true)"
if [[ -z "$log" ]]; then
  gh run view "$run" ${repo_arg[@]+"${repo_arg[@]}"} --json conclusion,url --jq '"run \(.url): \(.conclusion) (no failed-step log)"'
  exit 0
fi
# Here-strings, not pipes from printf: readers that stop early (head, grep -m1)
# would SIGPIPE the writer and abort the script under pipefail on large logs.
step="$(cut -f1-2 <<<"${log%%$'\n'*}")"
n="$(grep -n -i -m1 -E 'error|fail|fatal' <<<"$log" | cut -d: -f1 || true)"
n="${n:-1}"
out="$(printf 'run: %s\nstep: %s\nfirst error at log line %s:\n' "$run" "$step" "$n"
  cut -f3- <<<"$log" | sed -n "$(( n > 20 ? n - 20 : 1 )),$(( n + 19 ))p")"
printf '%s\n' "${out:0:2000}"
