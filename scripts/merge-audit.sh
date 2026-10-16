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
required_checks='lint build-iso boot-test'   # same list as scripts/autopilot/gates.sh
required_statuses='cross-review owner-gate'

problems=()
pr="$(gh api "repos/$repo/commits/$sha/pulls" \
  --jq '[.[] | select(.merged_at != null and .base.ref == "main")][0].number // empty')"

if [[ -z "$pr" ]]; then
  problems+=("pushed straight to main, not through a pull request")
  title="Unguarded change on main: direct push ${sha:0:7}"
else
  read -r head merged_by merged_at < <(gh api "repos/$repo/pulls/$pr" \
    --jq '"\(.head.sha) \(.merged_by.login) \(.merged_at)"')
  # The audit can run after a late check finishes, so judge each gate by its latest
  # result recorded no later than merged_at (ISO 8601 UTC strings compare as text).
  # Judge every gate as it stood at merge time: anything that finished after merged_at
  # (e.g. a check that went green while this audit waited for a runner) doesn't count.
  # ISO-8601 UTC timestamps compare correctly as strings.
  runs="$(gh api --paginate "repos/$repo/commits/$head/check-runs?per_page=100" \
    --jq ".check_runs[] | select(.completed_at != null and .completed_at <= \"$merged_at\")
          | \"\(.completed_at)\t\(.name)\t\(.conclusion)\"" | sort)"
  for name in $required_checks; do
    c="$(awk -F'\t' -v n="$name" -v t="$merged_at" '$2 == n && ($1 <= t || $1 == "~") {c = $3} END {print c}' <<<"$runs")"
    [[ "$c" == success ]] || problems+=("check \`$name\` was ${c:-missing} at merge time")
  done
  # /statuses lists every status newest first; the combined /status only has the latest.
  statuses="$(gh api --paginate "repos/$repo/commits/$head/statuses?per_page=100" \
    --jq '.[] | "\(.context)\t\(.state)\t\(.description)\t\(.created_at)"')"
    c="$(awk -F'\t' -v n="$name" '$2 == n {c = $3} END {print c}' <<<"$runs")"
    [[ "$c" == success ]] || problems+=("check \`$name\` was ${c:-not finished} at merge time")
  done
  # The statuses list is newest first and keeps history, so take the newest one per
  # context that existed when the PR merged.
  statuses="$(gh api --paginate "repos/$repo/commits/$head/statuses?per_page=100" \
    --jq ".[] | select(.created_at <= \"$merged_at\") | \"\(.context)\t\(.state)\t\(.description)\"")"
  for ctx in $required_statuses; do
    line="$(awk -F'\t' -v n="$ctx" -v t="$merged_at" '$1 == n && $4 <= t {print; exit}' <<<"$statuses")"
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
