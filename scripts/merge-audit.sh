#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 ZeeOS contributors
# Audits a commit that landed on main. Branch protection isn't available on this
# GitHub plan, so nothing *stops* an unguarded merge; this makes sure one never goes
# unnoticed. Opens a needs-human issue when the commit came from:
#   - a direct push (no merged PR), or
#   - a PR whose head commit didn't have every gate green at merge time.
# Usage: scripts/merge-audit.sh <sha>     Env: GITHUB_REPOSITORY, GH_TOKEN, DRY_RUN
set -euo pipefail

sha="${1:?usage: merge-audit.sh <sha>}"
repo="${GITHUB_REPOSITORY:?}"
# Required gates come from main's branch protection (the source of truth; readable without
# admin rights). Commit statuses posted by gates.sh are judged as statuses, the rest as check runs.
status_gates=' cross-review owner-gate '
required="$(gh api "repos/$repo/branches/main" --jq '.protection.required_status_checks.contexts // [] | .[]' 2>/dev/null || true)"
# Fallback (no protection, or the API failed): the full gates.sh list, so an error can
# never weaken the audit.
[[ -n "$required" ]] || required=$'lint\nbuild-iso\nboot-test\ncross-review\nowner-gate'
required_checks=""; required_statuses=""
for ctx in $required; do
  if [[ "$status_gates" == *" $ctx "* ]]; then required_statuses+="$ctx "; else required_checks+="$ctx "; fi
done

problems=()
# Right after a merge, GitHub's commit -> PR lookup can briefly come back empty (seen with
# #43 -> #47), so retry before concluding it was a direct push. Never trust the commit
# message ("Merge pull request #N"): a direct push can claim anything.
pr=""
for _ in 1 2 3 4 5 6; do
  pr="$(gh api "repos/$repo/commits/$sha/pulls" \
    --jq '[.[] | select(.merged_at != null and .base.ref == "main")][0].number // empty')"
  [[ -n "$pr" ]] && break
  sleep "${AUDIT_RETRY_SECONDS:-15}"
done

if [[ -z "$pr" ]]; then
  problems+=("pushed straight to main, not through a pull request")
  title="Unguarded change on main: direct push ${sha:0:7}"
else
  read -r head merged_by merged_at < <(gh api "repos/$repo/pulls/$pr" \
    --jq '"\(.head.sha) \(.merged_by.login) \(.merged_at)"')
  # Judge every gate as it stood at merge time: anything that finished after merged_at
  # (e.g. a check that went green while this audit waited for a runner) doesn't count.
  # ISO-8601 UTC timestamps compare correctly as strings. filter=all keeps runs that a
  # post-merge rerun superseded; the default (latest) would drop them.
  runs="$(gh api --paginate "repos/$repo/commits/$head/check-runs?per_page=100&filter=all" \
    --jq ".check_runs[] | select(.completed_at != null and .completed_at <= \"$merged_at\")
          | \"\(.completed_at)\t\(.name)\t\(.conclusion)\"" | sort)"
  for name in $required_checks; do
    c="$(awk -F'\t' -v n="$name" '$2 == n {c = $3} END {print c}' <<<"$runs")"
    [[ "$c" == success ]] || problems+=("check \`$name\` was ${c:-not finished} at merge time")
  done
  # The statuses list is newest first and keeps history, so take the newest one per
  # context that existed when the PR merged.
  statuses="$(gh api --paginate "repos/$repo/commits/$head/statuses?per_page=100" \
    --jq ".[] | select(.created_at <= \"$merged_at\") | \"\(.context)\t\(.state)\t\(.description)\"")"
  for ctx in $required_statuses; do
    line="$(awk -F'\t' -v n="$ctx" '$1 == n {print; exit}' <<<"$statuses")"
    state="$(cut -f2 <<<"$line")"
    [[ "$state" == success ]] || problems+=("gate \`$ctx\` was ${state:-missing} at merge time${line:+: $(cut -f3 <<<"$line")}")
  done
  title="Unguarded merge on main: #$pr"
fi

if [[ ${#problems[@]} -eq 0 ]]; then
  echo "#$pr merged with every gate green at ${head:0:7}"
  exit 0
fi

# shellcheck disable=SC2016  # backticks are Markdown in the issue body
body="$(printf 'Commit %s landed on `main` without passing every merge gate.\n\n' "$sha"
  if [[ -n "$pr" ]]; then printf -- '- PR: #%s (head %s), merged by @%s\n' "$pr" "${head:0:7}" "$merged_by"; fi
  printf -- '- %s\n' "${problems[@]}"
  printf '\nIf you merged this on purpose, close this issue. Otherwise revert it, and check which session or token merged it.\n')"

echo "$title"; echo "$body"
if gh issue list --repo "$repo" --state open --search "\"$title\" in:title" --json number --jq '.[].number' | grep -q .; then
  echo "issue already open"; exit 0
fi
if [[ -n "${DRY_RUN:-}" ]]; then echo "DRY: would open issue"; exit 0; fi
gh issue create --repo "$repo" --title "$title" --label needs-human --body "$body"
