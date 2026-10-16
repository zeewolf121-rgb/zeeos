#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Clears merge-audit issues with an after-the-fact review by the other model
# (docs/AUTOPILOT.md §11). For each open "Unguarded merge on main: #N" issue:
#   - hard stop (installer-disk, signing) or blocking review findings -> needs-human
#   - the other model reviewed #N's head commit, nothing blocking, CI green -> close
#   - otherwise request that review; nothing clean within 24 h -> needs-human
# Direct pushes ("Unguarded change on main: direct push ...") stay with the owner.
# Usage: scripts/autopilot/audit-review.sh     Env: see lib.sh; CODEX_TOKEN
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/autopilot/lib.sh
. "$here/lib.sh"

ESCALATED='<!-- audit-review escalated -->'
day_ago="$(date -u -d '24 hours ago' +%FT%TZ 2>/dev/null || date -u -v-24H +%FT%TZ)"

escalate() { # issue reason
  w gh issue edit "$1" --repo "$REPO" --add-label needs-human >/dev/null
  w gh issue comment "$1" --repo "$REPO" --body "$ESCALATED@$OWNER the post-merge review can't clear this: $2" >/dev/null
  log "audit #$1: needs-human ($2)"
}

issues="$(gh issue list --repo "$REPO" --state open --limit 100 --search '"Unguarded merge on main" in:title' \
  --json number,createdAt,title --jq '.[] | "\(.number)\t\(.createdAt)\t\(.title)"')"
while IFS=$'\t' read -r issue created title; do
  [[ "$title" =~ ^Unguarded\ merge\ on\ main:\ \#([0-9]+)$ ]] || continue
  pr="${BASH_REMATCH[1]}"
  if gh api --paginate "repos/$REPO/issues/$issue/comments" --jq '.[].body' | grep -qF "$ESCALATED"; then
    continue  # already handed to the owner
  fi
  # A hard-stop PR merged with a gate red always goes to the owner, approved or not.
  out="$("$here/gates.sh" hard-stop "$pr" 2>/dev/null)" || out="couldn't check hard stops"
  if [[ -n "$out" ]]; then escalate "$issue" "#$pr is an owner stop ($out)"; continue; fi
  if ! out="$("$here/gates.sh" cross-review "$pr" 2>/dev/null)"; then
    if [[ "$out" != waiting* ]]; then escalate "$issue" "#$pr review: $out"; continue; fi
    "$here/gates.sh" request-review "$pr" || true
  elif ! out="$("$here/gates.sh" checks "$pr" 2>/dev/null)"; then
    :  # reviewed, but CI isn't green yet; wait for it like for the review
  else
    w gh issue close "$issue" --repo "$REPO" \
      --comment "Cleared by autopilot: #$pr was reviewed by the other model after the merge with nothing blocking, and its required checks are green." >/dev/null
    log "audit #$issue: closed, #$pr reviewed after merge"
    continue
  fi
  if [[ "$created" < "$day_ago" ]]; then escalate "$issue" "#$pr still not cleared after 24 h: $out"; fi
done <<<"$issues"
