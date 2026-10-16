#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# fix-on-failure (docs/AUTOPILOT.md §4): a required check failed on an agent PR.
# Retry by sending the CI summary back to the authoring model, at most once per commit and
# AUTOPILOT_MAX_RETRIES (default 2) times per PR; after that label needs-human and ping the owner.
# With --review <pr>: the same for unresolved blocking review comments (P0/P1, [blocking]),
# with its own counter; called by gates.sh merge when they are all that blocks cross-review.
# Usage: scripts/autopilot/fix-retry.sh <head-branch> <head-sha> <run-id>
#        scripts/autopilot/fix-retry.sh --review <pr>
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/autopilot/lib.sh
. "$here/lib.sh"

give_up() { # pr what
  w gh issue edit "$1" --repo "$REPO" --add-label needs-human >/dev/null
  local num; num="$(linked_issue "$1")"
  if [[ -n "$num" ]]; then w gh issue edit "$num" --repo "$REPO" --add-label needs-human >/dev/null; fi
  w gh pr comment "$1" --repo "$REPO" --body "@$OWNER $2 Labelled needs-human; autopilot leaves this PR alone until the label is removed." >/dev/null
}

if [[ "${1:-}" == --review ]]; then
  pr="${2:?pr}"; max="${AUTOPILOT_MAX_REVIEW_FIXES:-2}"
  sha="$(pr_head "$pr")"; model="$(pr_model "$pr")"
  case "$model" in claude|codex) ;; *) exit 0 ;; esac
  has_label "$pr" needs-human && exit 0
  bodies="$(gh api --paginate "repos/$REPO/issues/$pr/comments" --jq '.[].body')"
  grep -qF "<!-- autopilot-review-fix sha=$sha " <<<"$bodies" && exit 0
  tries="$(grep -c '<!-- autopilot-review-fix ' <<<"$bodies" || true)"
  if (( tries >= max )); then
    give_up "$pr" "Blocking review comments are still unresolved at ${sha:0:7} after $max automatic fix rounds."
    log "#$pr needs-human after $max review fixes"; exit 0
  fi
  n=$((tries + 1))
  w gh pr comment "$pr" --repo "$REPO" --body "<!-- autopilot-review-fix sha=$sha n=$n -->Automatic review fix $n/$max: sending the unresolved blocking review comments at ${sha:0:7} back to $model." >/dev/null
  case "$model" in
    claude) w gh workflow run agent-dispatch.yml --repo "$REPO" -f pr="$pr" -f mode=fix ;;
    codex)
      [[ -n "${CODEX_TOKEN:-}" ]] || { log "#$pr: no CODEX_TOKEN for the Codex review fix"; exit 0; }
      GH_TOKEN="$CODEX_TOKEN" w gh pr comment "$pr" --repo "$REPO" --body "@codex address the unresolved [blocking] review comments on this PR, push the fixes to this branch, and reply on each thread. Stay inside your role's directories (AGENTS.md)." >/dev/null ;;
  esac
  log "#$pr: review fix $n/$max sent to $model"; exit 0
fi

branch="${1:?branch}"; sha="${2:?sha}"; run="${3:?run-id}"
max="${AUTOPILOT_MAX_RETRIES:-2}"
url="https://github.com/$REPO/actions/runs/$run"

pr="$(gh pr list --repo "$REPO" --head "$branch" --state open --json number --jq '.[0].number // empty')"
[[ -n "$pr" ]] || { log "no open PR for $branch"; exit 0; }
[[ "$(pr_head "$pr")" == "$sha" ]] || { log "#$pr: failure is for an old commit; ignored"; exit 0; }
model="$(pr_model "$pr")"
case "$model" in claude|codex) ;; *) log "#$pr: $model PR, no automatic retry"; exit 0 ;; esac
has_label "$pr" needs-human && { log "#$pr already needs-human"; exit 0; }

bodies="$(gh api --paginate "repos/$REPO/issues/$pr/comments" --jq '.[].body')"
grep -qF "<!-- autopilot-retry sha=$sha " <<<"$bodies" && { log "#$pr: ${sha:0:7} already retried"; exit 0; }
tries="$(grep -c '<!-- autopilot-retry ' <<<"$bodies" || true)"
summary="$("$here/../ci-summary.sh" "$run" "$REPO" 2>/dev/null || echo "(no summary; see $url)")"

if (( tries >= max )); then
  give_up "$pr" "CI still fails on ${sha:0:7} after $max automatic retries ($url)."
  log "#$pr needs-human after $max retries"
  exit 0
fi

n=$((tries + 1))
w gh pr comment "$pr" --repo "$REPO" --body "<!-- autopilot-retry sha=$sha n=$n -->Automatic retry $n/$max for the CI failure in $url:
\`\`\`
$summary
\`\`\`" >/dev/null
case "$model" in
  claude) w gh workflow run agent-dispatch.yml --repo "$REPO" -f pr="$pr" -f mode=fix -f run="$run" ;;
  codex)
    [[ -n "${CODEX_TOKEN:-}" ]] || { log "#$pr: no CODEX_TOKEN for the Codex retry"; exit 0; }
    GH_TOKEN="$CODEX_TOKEN" w gh pr comment "$pr" --repo "$REPO" --body "@codex fix the CI failure on this PR (attempt $n/$max). Summary of the failed run $url:
\`\`\`
$summary
\`\`\`
Push the fix to this branch. Stay inside your role's directories (AGENTS.md)." >/dev/null ;;
esac
log "#$pr: retry $n/$max sent to $model"
