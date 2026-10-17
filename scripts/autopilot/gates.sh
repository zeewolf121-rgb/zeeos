#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Merge gates for one PR (docs/AUTOPILOT.md §2–3, §7).
# Usage: scripts/autopilot/gates.sh <cross-review|owner-gate|status|request-review|merge> <pr>
#   cross-review    the other model reviewed the head commit, no unresolved blocking threads
#   owner-gate      hard-stop PRs (labels/paths) need the owner's approval of the head commit
#   status          post both results as commit statuses on the head commit
#   request-review  ask the other model to review the head commit (once per commit)
#   merge           merge if every gate passes; hard-stop PRs are left for the owner
#   review-model    model id for a Claude review: Opus for installer-disk work (PR or linked issue)
#   blocking        print the unresolved blocking review comments (input for a review fix)
# Env: see lib.sh; CODEX_TOKEN (owner token for "@codex review" comments).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/autopilot/lib.sh
. "$here/lib.sh"

REQUIRED_CHECKS='lint build-iso boot-test'

threads_json() { # all review threads of a PR (id, resolved, outdated, first comment)
  # shellcheck disable=SC2016  # GraphQL variables, not shell
  gh api graphql -F owner="$OWNER" -F name="${REPO#*/}" -F pr="$1" -f query='
    query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){
      pullRequest(number:$pr){reviewThreads(first:100){nodes{id isResolved isOutdated
        comments(first:1){nodes{author{login} body}}}}}}}' \
    --jq '.data.repository.pullRequest.reviewThreads.nodes'
}
unresolved_threads() { # "login first-comment" per unresolved thread that still applies
  # Outdated threads (the lines they point at were changed since) don't block: the reviewer
  # has already reviewed the head commit when this is consulted, and re-flags what remains.
  threads_json "$1" | jq -r '.[] | select((.isResolved | not) and (.isOutdated | not))
    | .comments.nodes[0] | "\(.author.login) \(.body | gsub("\n"; " "))"'
}
resolve_superseded() { # pr reviewer-login-prefix: resolve that reviewer's outdated open threads
  # Only the gate does this, only after the reviewer's review of the head commit came back
  # clean; the fixer never resolves its reviewer's threads (no self-approval).
  local id
  for id in $(threads_json "$1" | jq -r --arg who "$2" '.[] | select((.isResolved | not) and .isOutdated
      and (.comments.nodes[0].author.login | startswith($who))) | .id'); do
    # shellcheck disable=SC2016  # GraphQL variables, not shell
    w gh api graphql -F id="$id" -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id}}}' >/dev/null
    log "#$1: resolved superseded review thread $id"
  done
}
reviews_by() { # login-prefix -> commit ids of their reviews
  gh api --paginate "repos/$REPO/pulls/$1/reviews" \
    --jq ".[] | select(.user.login | startswith(\"$2\")) | .commit_id"
}
comments_by() { # login-prefix -> comment bodies
  gh api --paginate "repos/$REPO/issues/$1/comments" \
    --jq ".[] | select(.user.login | startswith(\"$2\")) | .body"
}
pushed_at() { gh api "repos/$REPO/commits/$1" --jq .commit.committer.date; }

codex_reviewed() { # pr sha: Codex finished reviewing this exact commit, findings posted
  # Codex keeps machine-readable state in its summary comment. Its "Completed" can appear
  # before the review (and its P0/P1 threads) is posted, so when it reports findings we also
  # wait for the review object on the head commit (the race behind #65).
  local st
  st="$(comments_by "$1" "$CODEX_BOT" | sed -n 's/.*codex-review-state:v1 \({.*}\) -->.*/\1/p' | tail -n1)"
  if [[ -n "$st" ]]; then
    jq -e --arg s "$2" '.code_review.commit_sha == $s and .code_review.status == "completed"' <<<"$st" >/dev/null \
      || return 1
    if jq -e '.code_review.has_any_findings != true' <<<"$st" >/dev/null; then return 0; fi
    reviews_by "$1" "$CODEX_BOT" | grep -qx "$2"; return
  fi
  # Older summaries without the state block.
  reviews_by "$1" "$CODEX_BOT" | grep -qx "$2" && return 0
  comments_by "$1" "$CODEX_BOT" | grep -F 'Code Review' | grep -F 'Completed' | grep -qF "\`${2:0:7}\`"
}
claude_verdict() { # pr sha -> pass | fail | (empty)
  # The marker is posted by agent-dispatch's claude-review job (github-actions). It only counts
  # if its run id really is that job on main, so no other workflow or LLM step can forge one.
  local m v run
  m="$(comments_by "$1" 'github-actions' | grep -oE "<!-- claude-review sha=$2 verdict=[a-z]+ run=[0-9]+ -->" | tail -n1)"
  [[ -n "$m" ]] || return 0
  v="$(sed -E 's/.*verdict=([a-z]+).*/\1/' <<<"$m")"; run="$(sed -E 's/.*run=([0-9]+).*/\1/' <<<"$m")"
  if [[ "$(gh api "repos/$REPO/actions/runs/$run" --jq '"\(.path) \(.head_branch)"' 2>/dev/null)" != ".github/workflows/agent-dispatch.yml main" ]] \
     || ! gh api "repos/$REPO/actions/runs/$run/jobs" --jq '.jobs[].name' | grep -qx claude-review; then
    echo unverified; return 0
  fi
  echo "$v"
}

cross_review() {
  local pr="$1" sha model threads v
  sha="$(pr_head "$pr")"; model="$(pr_model "$pr")"
  if has_label "$pr" needs-decision; then echo "models disagree (needs-decision); owner decides"; return 1; fi
  threads="$(unresolved_threads "$pr")"
  case "$model" in
    claude)
      codex_reviewed "$pr" "$sha" || { echo "waiting for Codex review of ${sha:0:7}"; return 1; }
      if grep -qE "^${CODEX_BOT}[^ ]* .*badge/P[01]-" <<<"$threads"; then
        echo "unresolved Codex P0/P1 comments"; return 1
      fi ;;
    codex)
      v="$(claude_verdict "$pr" "$sha")"
      [[ -n "$v" ]] || { echo "waiting for Claude review of ${sha:0:7}"; return 1; }
      [[ "$v" == pass ]] || { echo "Claude review verdict: $v"; return 1; }
      if grep -qE "^${CLAUDE_BOT}[^ ]* [* ]*\[blocking\]" <<<"$threads"; then
        echo "unresolved Claude [blocking] comments"; return 1
      fi ;;
    human)
      if codex_reviewed "$pr" "$sha" || [[ "$(claude_verdict "$pr" "$sha")" == pass ]]; then :; else
        echo "waiting for a model review of ${sha:0:7}"; return 1
      fi
      if grep -qE "^(${CODEX_BOT}[^ ]* .*badge/P[01]-|${CLAUDE_BOT}[^ ]* [* ]*\[blocking\])" <<<"$threads"; then
        echo "unresolved blocking comments"; return 1
      fi ;;
    fork) echo "PR from a fork: autopilot never reviews or merges it; the owner does"; return 1 ;;
    *) echo "can't tell which model wrote this PR; label the linked issue model:claude|codex"; return 1 ;;
  esac
  echo "reviewed by the other model at ${sha:0:7}, nothing blocking"
}

hard_stop_reasons() { # empty if none
  # Labels count if they are on the PR now, were ever put on it, or are on its linked issue,
  # so removing a label can't lift a hard stop.
  local pr="$1" l r="" hits seen n
  seen=""
  for n in "$pr" $(linked_issue "$pr"); do
    seen+="$(labels_of "$n"; gh api --paginate "repos/$REPO/issues/$n/events" \
      --jq '.[] | select(.event == "labeled") | .label.name')"$'\n'
  done
  for l in $HARD_STOP_LABELS; do if grep -qxF "$l" <<<"$seen"; then r+="label:$l "; fi; done
  hits="$(gh api --paginate "repos/$REPO/pulls/$pr/files" --jq '.[].filename' | grep -E "$HARD_STOP_PATHS" || true)"
  if [[ -n "$hits" ]]; then r+="files:$(head -n3 <<<"$hits" | paste -sd, -)"; fi
  printf '%s' "${r% }"
}
owner_approved() { # pr sha
  local pr="$1" sha="$2" last ev actor at reviews_approved
  reviews_approved="$(gh api --paginate "repos/$REPO/pulls/$pr/reviews" \
    --jq ".[] | select(.user.login == \"$OWNER\" and .state == \"APPROVED\") | .commit_id")"
  grep -qx "$sha" <<<"$reviews_approved" && return 0
  has_label "$pr" owner-approved || return 1
  last="$(gh api --paginate "repos/$REPO/issues/$pr/events" \
    --jq '.[] | select(.label.name == "owner-approved") | "\(.event) \(.actor.login) \(.created_at)"' | tail -n1)"
  read -r ev actor at <<<"$last"
  [[ "$ev" == labeled && "$actor" == "$OWNER" ]] || return 1
  [[ "$at" > "$(pushed_at "$sha")" ]]   # ISO-8601 UTC strings sort lexically
}
owner_gate() {
  local pr="$1" sha reasons
  sha="$(pr_head "$pr")"; reasons="$(hard_stop_reasons "$pr")"
  if [[ -z "$reasons" ]]; then echo "no owner approval needed"; return 0; fi
  if owner_approved "$pr" "$sha"; then echo "owner approved ${sha:0:7} ($reasons)"; return 0; fi
  echo "needs owner approval of ${sha:0:7}: $reasons"; return 1
}

checks_green() { # pr sha: latest run of each required check succeeded
  local runs name c bad=""
  runs="$(gh api --paginate "repos/$REPO/commits/$2/check-runs?per_page=100" \
    --jq '.check_runs[] | "\(.completed_at // "~")\t\(.name)\t\(.conclusion // "pending")"' | sort)"
  for name in $REQUIRED_CHECKS; do
    c="$(awk -F'\t' -v n="$name" '$2 == n {c = $3} END {print c}' <<<"$runs")"
    [[ "$c" == success ]] || bad+="$name=${c:-missing} "
  done
  if [[ -n "$bad" ]]; then echo "checks not green: ${bad% }"; return 1; fi
}

post_status() { # sha context ok? description
  local state=failure; [[ "$3" == 0 ]] && state=success
  w gh api "repos/$REPO/statuses/$1" -f state="$state" -f context="$2" \
    -f description="$(cut -c1-139 <<<"$4")" >/dev/null
}
status() {
  local pr="$1" sha out rc
  sha="$(pr_head "$pr")"
  out="$(cross_review "$pr")" && rc=0 || rc=$?; post_status "$sha" cross-review "$rc" "$out"; log "#$pr cross-review: $out"
  out="$(owner_gate "$pr")" && rc=0 || rc=$?; post_status "$sha" owner-gate "$rc" "$out"; log "#$pr owner-gate: $out"
}

request_review() {
  local pr="$1" sha model since
  sha="$(pr_head "$pr")"; model="$(pr_model "$pr")"; since="$(pushed_at "$sha")"
  case "$model" in
    claude|human)
      codex_reviewed "$pr" "$sha" && return 0
      if gh api --paginate "repos/$REPO/issues/$pr/comments" \
          --jq ".[] | select(.body == \"@codex review\" and .created_at > \"$since\") | .id" | grep -q .; then
        return 0
      fi
      [[ -n "${CODEX_TOKEN:-}" ]] || { log "#$pr: no CODEX_TOKEN, can't request Codex review"; return 0; }
      GH_TOKEN="$CODEX_TOKEN" w gh pr comment "$pr" --repo "$REPO" --body "@codex review" >/dev/null
      log "#$pr: requested Codex review of ${sha:0:7}" ;;
    codex)
      [[ -n "$(claude_verdict "$pr" "$sha")" ]] && return 0
      if gh api --paginate "repos/$REPO/issues/$pr/comments" --jq '.[].body' | grep -qF "<!-- claude-review-requested sha=$sha -->"; then
        return 0
      fi
      w gh workflow run agent-dispatch.yml --repo "$REPO" -f pr="$pr" -f mode=review
      w gh pr comment "$pr" --repo "$REPO" --body "<!-- claude-review-requested sha=$sha -->Requested Claude review of ${sha:0:7}." >/dev/null
      log "#$pr: requested Claude review of ${sha:0:7}" ;;
  esac
}

protected() { gh api "repos/$REPO/branches/main/protection" >/dev/null 2>&1; }

merge() {
  local pr="$1" sha info out reasons
  info="$(gh pr view "$pr" --repo "$REPO" --json isDraft,mergeable,state --jq '"\(.state) \(.isDraft) \(.mergeable)"')"
  [[ "$info" == "OPEN false MERGEABLE" ]] || { echo "#$pr not mergeable ($info)"; return 1; }
  sha="$(pr_head "$pr")"
  out="$(checks_green "$pr" "$sha")" || { echo "#$pr $out"; return 1; }
  if ! out="$(cross_review "$pr")"; then
    request_review "$pr"
    # Blocking review comments go back to the authoring model (fix-retry.sh --review).
    if [[ "$out" == unresolved* || "$out" == "Claude review verdict: fail" ]]; then
      "$here/fix-retry.sh" --review "$pr" || true
    fi
    echo "#$pr cross-review: $out"; return 1
  fi
  # The reviewer's latest review of the head is clean: clear its superseded (outdated) threads,
  # which GitHub's required conversation resolution would otherwise block on.
  case "$(pr_model "$pr")" in
    claude) resolve_superseded "$pr" "$CODEX_BOT" ;;
    codex) resolve_superseded "$pr" "$CLAUDE_BOT" ;;
    *) resolve_superseded "$pr" "$CODEX_BOT"; resolve_superseded "$pr" "$CLAUDE_BOT" ;;
  esac
  reasons="$(hard_stop_reasons "$pr")"
  if [[ -n "$reasons" ]]; then
    # Hard stop: never merged by autopilot. Ping the owner once per commit.
    if ! gh api --paginate "repos/$REPO/issues/$pr/comments" --jq '.[].body' | grep -qF "<!-- autopilot-owner-merge sha=$sha -->"; then
      w gh pr comment "$pr" --repo "$REPO" --body "<!-- autopilot-owner-merge sha=$sha -->@$OWNER all automated gates pass at ${sha:0:7}. Hard stop ($reasons): approve and merge yourself." >/dev/null
    fi
    echo "#$pr hard stop, left for the owner ($reasons)"; return 1
  fi
  out="$(owner_gate "$pr")" || { echo "#$pr owner-gate: $out"; return 1; }
  if protected; then w gh pr merge "$pr" --repo "$REPO" --auto --squash --delete-branch
  else w gh pr merge "$pr" --repo "$REPO" --squash --delete-branch --match-head-commit "$sha"; fi
  log "#$pr merged at ${sha:0:7}"
}

cmd="${1:?usage: gates.sh <cross-review|owner-gate|status|request-review|merge|review-model|blocking> <pr>}"; pr="${2:?pr}"
case "$cmd" in
  cross-review) cross_review "$pr" ;;
  owner-gate) owner_gate "$pr" ;;
  status) status "$pr" ;;
  request-review) request_review "$pr" ;;
  merge) merge "$pr" ;;
  blocking)
    unresolved_threads "$pr" | grep -E "^(${CODEX_BOT}[^ ]* .*badge/P[01]-|${CLAUDE_BOT}[^ ]* [* ]*\[blocking\])" \
      | sed -E 's/<[^>]*>//g; s/!\[[^]]*\]\([^)]*\)//g' | cut -c1-1500 || true ;;
  review-model)
    if [[ "$(hard_stop_reasons "$pr")" == *label:installer-disk* ]]; then echo claude-opus-5-5; else echo claude-sonnet-5-5; fi ;;
  *) echo "unknown command: $cmd" >&2; exit 2 ;;
esac
