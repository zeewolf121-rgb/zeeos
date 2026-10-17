#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline tests for scripts/autopilot/* against a fake `gh` that answers from JSON fixtures
# and records every write. Run by `make lint`. Needs bash and jq.
# shellcheck disable=SC2016,SC2034  # ok() evals its checks later, on purpose
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export FIX="$tmp/fix" CALLS="$tmp/calls" GITHUB_REPOSITORY=o/r AUTOPILOT_STAGGER=0 PATH="$tmp/bin:$PATH"

cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fake gh: reads answer from $FIX/<key>.json (filtered by --jq); writes are logged to $CALLS.
jqx=""; key=""; write=""; args=("$@"); i=0
while (( i < ${#args[@]} )); do
  a="${args[i]}"
  case "$a" in
    --jq) jqx="${args[i+1]}"; i=$((i+2)); continue ;;
    -X) [[ "${args[i+1]}" != GET ]] && write=1 ;;
    -f|-F) [[ "${args[1]:-}" != graphql ]] && write=1 ;;
  esac
  i=$((i+1))
done
case "$1 $2" in
  "api graphql") key=graphql ;;
  "api "*) key="$(printf '%s\n' "${args[@]:1}" | grep -m1 '^repos/' | sed 's/[?].*//; s#^repos/o/r/##; s#/#_#g')" ;;
  "issue view"|"pr view") key="${1}_view_$3" ;;
  "issue list"|"pr list")
    key="${1}_list"
    for ((j=0; j<${#args[@]}; j++)); do
      [[ "${args[j]}" == --label ]] && key+="_${args[j+1]}"
      [[ "${args[j]}" == --milestone ]] && key+="_ms"
    done ;;
  "run list") key=runs ;;
  "repo view") echo o/r; exit 0 ;;
  *) write=1 ;;
esac
if [[ "$1 $2" == "workflow run" && -n "${FAIL_WORKFLOW_RUN:-}" ]]; then echo "CALL $*" >>"$CALLS"; exit 1; fi
[[ "$*" == *mutation* ]] && write=1
if [[ -n "$write" ]]; then echo "CALL $*" >>"$CALLS"; [[ "$1 $2" == "issue create" ]] && echo "https://x/issues/99"; exit 0; fi
f="$FIX/$key.json"
[[ -f "$f" ]] || { [[ "$key" == *protection* ]] && exit 1; echo "[]" >"$f"; }
if [[ -n "$jqx" ]]; then jq -r "$jqx" "$f"; else cat "$f"; fi
EOF
chmod +x "$tmp/bin/gh"

pass=0; fail=0
ok() { [[ -n "${VERBOSE:-}" ]] && echo "== $1"; if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
reset() { rm -rf "$FIX"; mkdir -p "$FIX"; : >"$CALLS"; }
fx() { cat >"$FIX/$1.json"; }
sha=abcdef1234567890

# A Claude PR (#5 from agent/image-builder/6-x, issue #6 model:claude) at $sha.
claude_pr() {
  echo "{\"isCrossRepository\":false,\"headRefName\":\"agent/image-builder/6-kiwi\",\"headRefOid\":\"$sha\",\"body\":\"Closes #6\",\"labels\":[],\"isDraft\":false,\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\"}" | fx pr_view_5
  echo '{"labels":[{"name":"model:claude"},{"name":"agent:image-builder"}]}' | fx issue_view_6
  echo '{"labels":[]}' | fx issue_view_5
  echo '{"commit":{"committer":{"date":"2026-10-16T10:00:00Z"}}}' | fx "commits_$sha"
  echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' | fx graphql
  echo '[{"filename":"build/kiwi.xml"}]' | fx pulls_5_files
  echo "{\"check_runs\":[{\"name\":\"lint\",\"conclusion\":\"success\",\"completed_at\":\"1\"},{\"name\":\"build-iso\",\"conclusion\":\"success\",\"completed_at\":\"1\"},{\"name\":\"boot-test\",\"conclusion\":\"success\",\"completed_at\":\"1\"}]}" | fx "commits_${sha}_check-runs"
}
codex_done() { echo "[{\"user\":{\"login\":\"chatgpt-codex-connector[bot]\"},\"body\":\"| 📝 **Code Review** | ✅ **Completed** x | \`${sha:0:7}\` | Manual |\"}]" | fx issues_5_comments; }
gates() { if [[ -n "${VERBOSE:-}" ]]; then "$here/gates.sh" "$@" | tee /dev/stderr; else "$here/gates.sh" "$@" 2>/dev/null; fi; }


reset; claude_pr
ok "cross-review waits for Codex" '! gates cross-review 5 >/dev/null'
codex_done
ok "cross-review passes after Codex Completed on head" 'gates cross-review 5 >/dev/null'
echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"body":"![P1 Badge](https://img.shields.io/badge/P1-orange)"}]}}]}}}}}' | fx graphql
ok "unresolved Codex P1 blocks" '! gates cross-review 5 >/dev/null'
echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"body":"![P2 Badge](https://img.shields.io/badge/P2-yellow)"}]}}]}}}}}' | fx graphql
ok "unresolved Codex P2 does not block" 'gates cross-review 5 >/dev/null'
ok "plain PR needs no owner approval" 'gates owner-gate 5 >/dev/null'
ok "merge goes through when all gates pass" 'gates merge 5 >/dev/null && grep -q "CALL pr merge 5" "$CALLS"'

reset; claude_pr; codex_done
echo '[{"event":"labeled","label":{"name":"installer-disk"},"actor":{"login":"x"},"created_at":"2026-10-16T09:00:00Z"},{"event":"unlabeled","label":{"name":"installer-disk"},"actor":{"login":"x"},"created_at":"2026-10-16T09:30:00Z"}]' | fx issues_5_events
ok "removed installer-disk label still counts" '! gates owner-gate 5 >/dev/null'
ok "hard stop is never merged, owner pinged" '! gates merge 5 >/dev/null && ! grep -q "pr merge" "$CALLS" && grep -q "autopilot-owner-merge" "$CALLS"'

reset; claude_pr; codex_done
echo '[{"filename":".github/workflows/x.yml"}]' | fx pulls_5_files
echo '{"labels":[{"name":"owner-approved"}]}' | fx issue_view_5
echo '[{"event":"labeled","label":{"name":"owner-approved"},"actor":{"login":"github-actions[bot]"},"created_at":"2026-10-16T11:00:00Z"}]' | fx issues_5_events
ok "owner-approved by a bot doesn't count" '! gates owner-gate 5 >/dev/null'
echo '[{"event":"labeled","label":{"name":"owner-approved"},"actor":{"login":"o"},"created_at":"2026-10-16T09:00:00Z"}]' | fx issues_5_events
ok "owner-approved before the head commit doesn't count" '! gates owner-gate 5 >/dev/null'
echo '[{"event":"labeled","label":{"name":"owner-approved"},"actor":{"login":"o"},"created_at":"2026-10-16T11:00:00Z"}]' | fx issues_5_events
ok "owner-approved by the owner after the push counts" 'gates owner-gate 5 >/dev/null'

reset; claude_pr; codex_done
echo '[{"event":"labeled","label":{"name":"installer-disk"},"actor":{"login":"x"},"created_at":"2026-10-16T09:00:00Z"}]' | fx issues_6_events
ok "installer-disk once on the linked issue still counts" '! gates owner-gate 5 >/dev/null'

# Fork PR: even with a trusted-looking branch name, "Closes #6" and every gate green,
# autopilot never merges it (the repo is public; anyone can open one).
reset; claude_pr; codex_done
jq '.isCrossRepository = true | .headRefName = "agent/orchestrator/evil"' "$FIX/pr_view_5.json" >"$FIX/t" && mv "$FIX/t" "$FIX/pr_view_5.json"
ok "fork PR fails cross-review" '! gates cross-review 5 >/dev/null'
ok "fork PR is never merged" '! gates merge 5 >/dev/null && ! grep -q "pr merge" "$CALLS"'

# Merge guards are hard stops: a PR touching the merge-block hook or merge-audit needs the owner.
for f in .claude/hooks/block-merge.sh .claude/settings.json scripts/merge-audit.sh; do
  reset; claude_pr; codex_done
  echo "[{\"filename\":\"$f\"}]" | fx pulls_5_files
  ok "$f is a hard stop" '! gates owner-gate 5 >/dev/null && ! gates merge 5 >/dev/null && ! grep -q "pr merge" "$CALLS"'
done
reset; claude_pr; codex_done
echo '[{"filename":"scripts/merge-audit-notes.md"}]' | fx pulls_5_files
ok "a similarly named file is not a hard stop" 'gates owner-gate 5 >/dev/null'

# Review fix: unresolved Codex P1 on a green Claude PR -> one fix round per commit.
reset; claude_pr; codex_done
echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"body":"![P1 Badge](https://img.shields.io/badge/P1-orange) fix x"}]}}]}}}}}' | fx graphql
gates merge 5 >/dev/null || true
ok "blocking review comments -> review fix dispatched" 'grep -q "workflow run agent-dispatch.yml --repo o/r -f pr=5 -f mode=fix" "$CALLS" && grep -q "autopilot-review-fix sha=$sha n=1" "$CALLS"'
jq --arg m "<!-- autopilot-review-fix sha=$sha n=1 -->" '. + [{"user":{"login":"o"},"body":$m}]' "$FIX/issues_5_comments.json" >"$FIX/t" && mv "$FIX/t" "$FIX/issues_5_comments.json"
: >"$CALLS"; gates merge 5 >/dev/null || true
ok "at most one review fix per commit (cross-review still blocked by the P1)" '! grep -q "mode=fix" "$CALLS" && [[ "$(gates cross-review 5)" == unresolved* ]]'
ok "blocking prints the comment for the fix prompt" '[[ "$(gates blocking 5)" == *"fix x"* ]]'

# Codex review state (race behind #65): "completed" with findings needs the review object.
cstate() { echo "[{\"user\":{\"login\":\"chatgpt-codex-connector[bot]\"},\"body\":\"<!-- codex-review-state:v1 {\\\"code_review\\\":{\\\"commit_sha\\\":\\\"$1\\\",\\\"has_any_findings\\\":$2,\\\"status\\\":\\\"completed\\\"}} --> | 📝 **Code Review** | ✅ **Completed** x | \`${1:0:7}\` | Manual |\"}]"; }
reset; claude_pr
cstate "$sha" true | fx issues_5_comments
ok "findings reported but review not posted yet -> still waiting" '[[ "$(gates cross-review 5)" == waiting* ]]'
echo "[{\"user\":{\"login\":\"chatgpt-codex-connector[bot]\"},\"commit_id\":\"$sha\"}]" | fx pulls_5_reviews
ok "review object on head -> reviewed (threads decide)" 'gates cross-review 5 >/dev/null'
cstate deadbeef false | fx issues_5_comments; rm -f "$FIX/pulls_5_reviews.json"
ok "state for another commit -> waiting" '[[ "$(gates cross-review 5)" == waiting* ]]'
cstate "$sha" false | fx issues_5_comments
ok "clean state on head -> reviewed" 'gates cross-review 5 >/dev/null'

# Outdated blocking threads don't block a re-reviewed head; the gate resolves them on merge.
reset; claude_pr; codex_done
echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T1","isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"body":"![P1 Badge](https://img.shields.io/badge/P1-orange) old"}]}}]}}}}}' | fx graphql
ok "outdated P1 thread doesn't block" 'gates cross-review 5 >/dev/null'
gates merge 5 >/dev/null || true
ok "merge resolves the superseded thread" 'grep -q "resolveReviewThread" "$CALLS" && grep -q "id=T1" "$CALLS"'
echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T2","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"body":"![P1 Badge](https://img.shields.io/badge/P1-orange) live"}]}}]}}}}}' | fx graphql
ok "a P1 thread that still applies keeps blocking" '! gates cross-review 5 >/dev/null'

# The review-fix marker is written only after the dispatch succeeded.
: >"$CALLS"; FAIL_WORKFLOW_RUN=1 gates merge 5 >/dev/null || true
ok "failed review-fix dispatch leaves no marker (retried next run)" 'grep -q "mode=fix" "$CALLS" && ! grep -q "autopilot-review-fix" "$CALLS"'

# Codex PR: Claude verdict marker must come from agent-dispatch's claude-review job on main.
reset; claude_pr
jq '.headRefName = "codex/foo" | .body = ""' "$FIX/pr_view_5.json" >"$FIX/t" && mv "$FIX/t" "$FIX/pr_view_5.json"
echo "[{\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- claude-review sha=$sha verdict=pass run=77 -->\"}]" | fx issues_5_comments
echo '{"path":".github/workflows/orchestrator.yml","head_branch":"main"}' | fx actions_runs_77
ok "forged Claude verdict (wrong workflow) rejected" '! gates cross-review 5 >/dev/null'
echo '{"path":".github/workflows/agent-dispatch.yml","head_branch":"main"}' | fx actions_runs_77
echo '{"jobs":[{"name":"claude-review"}]}' | fx actions_runs_77_jobs
ok "verified Claude verdict passes" 'gates cross-review 5 >/dev/null'
sed -i.bak 's/verdict=pass/verdict=fail/' "$FIX/issues_5_comments.json" && rm -f "$FIX/issues_5_comments.json.bak"
: >"$CALLS"; CODEX_TOKEN=x gates merge 5 >/dev/null || true
ok "Claude fail verdict on a Codex PR -> review fix sent to Codex" 'grep -q "@codex address the unresolved" "$CALLS" && grep -q "autopilot-review-fix" "$CALLS"'

# Dispatch: caps, priority, labels.
reset
echo '[{"number":1,"createdAt":"2026-01-01","labels":[{"name":"ready"}]},{"number":2,"createdAt":"2026-02-01","labels":[{"name":"ready"},{"name":"priority:high"}]},{"number":3,"createdAt":"2026-03-01","labels":[{"name":"ready"}]}]' | fx issue_list_ready
echo '[{"labels":[{"name":"model:claude"}]}]' | fx issue_list_in-progress
for n in 1 2 3; do echo '{"labels":[{"name":"model:claude"},{"name":"agent:image-builder"},{"name":"ready"}]}' | fx "issue_view_$n"; done
"$here/dispatch.sh" 2>/dev/null
ok "only one Claude slot left: priority:high #2 goes first" 'grep -q "workflow run agent-dispatch.yml --repo o/r -f issue=2" "$CALLS" && [[ $(grep -c "workflow run" "$CALLS") == 1 ]]'

reset
echo '[{"number":1,"createdAt":"2026-01-01","labels":[{"name":"ready"}]}]' | fx issue_list_ready
echo '[{"labels":[{"name":"model:codex"},{"name":"needs-human"}]}]' | fx issue_list_in-progress
echo '{"labels":[{"name":"model:codex"},{"name":"agent:theme-designer"},{"name":"ready"}]}' | fx issue_view_1
"$here/dispatch.sh" 2>/dev/null
ok "a needs-human Codex issue doesn't hold the Codex slot" 'grep -q "issue=1" "$CALLS"'

reset
echo '[{"number":4,"createdAt":"2026-01-01","labels":[{"name":"ready"}]}]' | fx issue_list_ready
echo '{"labels":[{"name":"model:claude"},{"name":"agent:image-builder"},{"name":"ready"}]}' | fx issue_view_4
FAIL_WORKFLOW_RUN=1 "$here/dispatch.sh" 2>/dev/null
ok "failed dispatch gives the slot back" 'grep -q "issue edit 4 --repo o/r --remove-label in-progress --add-label ready" "$CALLS"'

reset; claude_pr
echo '{"labels":[{"name":"model:claude"},{"name":"agent:installer-engineer"},{"name":"installer-disk"}]}' | fx issue_view_6
ok "installer-disk on the linked issue -> Opus review" '[[ "$(gates review-model 5)" == claude-opus-5-5 ]]'

# Route: a Codex agent has no .claude/agents file; routing must still work.
reset
printf '%s\n' '{"labels":[{"name":"model:codex"},{"name":"agent:security-hardener"}],"body":"## Turn budget\nmedium 40"}' | fx issue_view_9
out="$(cd "$here/../.." && "$here/route.sh" 9 2>/dev/null)" || out="exit $?"
ok "route works for a Codex agent without a .claude/agents file" '[[ "$out" == *model=codex* && "$out" == *agent=security-hardener* ]]'

reset
echo '[{"number":7,"createdAt":"2026-01-05","labels":[{"name":"paused"},{"name":"in-progress"}]}]' | fx issue_list_paused
echo '[{"number":14,"createdAt":"2026-01-01","labels":[{"name":"ready"}]}]' | fx issue_list_ready
echo '[{"labels":[{"name":"model:claude"}]}]' | fx issue_list_in-progress
echo '{"labels":[{"name":"model:claude"},{"name":"agent:image-builder"},{"name":"paused"},{"name":"in-progress"}]}' | fx issue_view_7
echo '{"labels":[{"name":"model:claude"},{"name":"agent:desktop-shell"},{"name":"ready"}]}' | fx issue_view_14
"$here/dispatch.sh" 2>/dev/null
ok "paused issue gets the last slot before a ready one" 'grep -q "issue=7" "$CALLS" && ! grep -q "issue=14" "$CALLS"'

# Pause cap: 3 pauses without commits -> needs-human instead of another resume.
pause_fx() {
  reset
  echo '[{"number":7,"createdAt":"2026-01-05","labels":[{"name":"paused"},{"name":"in-progress"}]}]' | fx issue_list_paused
  echo '{"labels":[{"name":"model:claude"},{"name":"agent:image-builder"},{"name":"paused"},{"name":"in-progress"}]}' | fx issue_view_7
}
pz() { echo "{\"event\":\"$1\",\"label\":{\"name\":\"$2\"},\"created_at\":\"$3\"}"; }
pause_fx
echo "[$(pz labeled paused 2026-10-16T01:00:00Z),$(pz labeled paused 2026-10-16T02:00:00Z),$(pz labeled paused 2026-10-16T03:00:00Z)]" | fx issues_7_events
"$here/dispatch.sh" 2>/dev/null
ok "3 pauses, no branch -> needs-human, not resumed" 'grep -q "issue edit 7 --repo o/r --add-label needs-human" "$CALLS" && ! grep -q "issue=7" "$CALLS"'
pause_fx
echo "[$(pz labeled paused 2026-10-16T01:00:00Z),$(pz labeled paused 2026-10-16T02:00:00Z),$(pz unlabeled needs-human 2026-10-16T02:30:00Z),$(pz labeled paused 2026-10-16T03:00:00Z)]" | fx issues_7_events
"$here/dispatch.sh" 2>/dev/null
ok "owner clearing needs-human resets the pause count" 'grep -q "issue=7" "$CALLS"'
pause_fx
echo "[$(pz labeled paused 2026-10-16T01:00:00Z),$(pz labeled paused 2026-10-16T02:00:00Z),$(pz labeled paused 2026-10-16T03:00:00Z)]" | fx issues_7_events
echo '[{"object":{"sha":"c0ffee"}}]' | fx git_matching-refs_heads_agent_image-builder_7-
echo '{"commit":{"committer":{"date":"2026-10-16T02:30:00Z"}}}' | fx commits_c0ffee
"$here/dispatch.sh" 2>/dev/null
ok "pauses with commits in between keep resuming" 'grep -q "issue=7" "$CALLS"'

# Phase: milestone 1 opened with an open issue -> current 1; nothing for the LLM.
reset
echo '[{"number":2,"title":"Phase 1: Live","description":"[opened]"},{"number":3,"title":"Phase 2: Desk","description":""}]' | fx milestones
echo '[{"number":6,"state":"OPEN","labels":[{"name":"model:claude"},{"name":"agent:x"}]}]' | fx issue_list_ms
out="$("$here/phase.sh" status 2>/dev/null)"
ok "phase 1 current, no LLM needed" '[[ "$out" == *current=1* && "$out" == *needs_llm=false* ]]'
echo '[{"number":6,"state":"CLOSED","labels":[{"name":"model:claude"},{"name":"agent:x"}]}]' | fx issue_list_ms
echo '[{"databaseId":9}]' | fx runs
echo '{"jobs":[{"name":"gate","conclusion":"skipped"},{"name":"health","conclusion":"skipped"}]}' | fx actions_runs_9_jobs
out="$("$here/phase.sh" status 2>/dev/null)"
ok "skipped nightly (kill switch) doesn't count as green" '[[ "$out" == *prev_exit=false* && "$out" == *needs_llm=false* ]]'
echo '{"jobs":[{"name":"health","conclusion":"success"}]}' | fx actions_runs_9_jobs
out="$("$here/phase.sh" status 2>/dev/null)"
ok "phase 1 done + nightly green -> phase 2 needs opening" '[[ "$out" == *current=2* && "$out" == *needs_llm=true* ]]'

echo "selftest: $pass passed, $fail failed"
(( fail == 0 ))
