# Autopilot

Autopilot runs the MISSION §10–11 loop without a person in it: dispatch ready work, review it with the other model, merge what passes every gate, retry CI failures, and advance phases. Some things always stop for the owner (§7). This operating guide describes legacy mode;
§11 adds the opt-in codex-local controller and its stricter automatic lane. Governance changes
remain in PR #295; do not enable codex-local until that decision PR is accepted.

The code that decides what happens lives in `scripts/autopilot/` and runs from `main`. LLMs are used only where judgment is needed: implementing issues, reviewing PRs, opening a new phase's issues, and writing the run summary.

**Kill switch:** set the repo variable `AUTOPILOT` to anything other than `on` (Settings → Secrets and variables → Actions → Variables, or `gh variable set AUTOPILOT --body off`). Every autopilot and agent workflow checks it at job level and does nothing. The CI checks themselves (`lint`, `build-iso`, `boot-test`) keep running, so PRs still show their real state.

## Workflows

| Workflow | Trigger | Does |
|---|---|---|
| `orchestrator.yml` | every 3 h (`:23`), manual | §1: gates + merges, `ready` labels, dispatch, phase advance, owner release-readiness report, run summary |
| `cross-review.yml` | PR events, reviews, comments (resolved threads are picked up by the next event or orchestrator run) | §2: posts the `cross-review` and `owner-gate` statuses; merges when every gate passes |
| `agent-dispatch.yml` | issue labels, `workflow_dispatch`, PR opened/ready | Starts Claude or Codex on an issue; Claude fix and review runs; asks for the cross-model review |
| `fix-on-failure.yml` | `lint` / `build-iso` finished on a PR | §4: retry or `needs-human`; on success, requests the review or merges |
| `nightly-health.yml` | daily 02:17 UTC, manual | §5: build + boot-test `main`; failure opens a `ready` + `priority:high` fix issue |
| `resume.yml` | every 2 h (`:41`), manual | §6: re-dispatch `paused` issues oldest-first |
| `release.yml` | tag push, `workflow_dispatch` | §8: build, `SHA256SUMS`, minisign, GitHub release (rc = pre-release) |
| `claude.yml` | `@claude` comments **by the owner** | Interactive Claude (from the GitHub app install, restricted to the owner) |
| `build-iso.yml` / `boot-test.yml` | every PR, called by nightly + release | CI. Required checks `build-iso` and `boot-test` always report |

`orchestrator.yml` and `resume.yml` share the job-level concurrency group `autopilot` (job-level, so skipped runs never bump a queued one), so runs never overlap.

## 1. Orchestrator run

1. **Deterministic** (`scripts/autopilot/orchestrate.sh`, no LLM tokens):
   - For every open, non-draft PR without `needs-human`, post the gate statuses and merge it if everything passes (§3).
   - In the current phase, label `ready` every open issue that has `model:` + `agent:` labels, isn't started, and whose `blocked-by:#N` issues are closed.
   - Dispatch `ready` issues (`priority:high` first, then oldest) within the caps: **3 Claude + 1 Codex** in progress (label `in-progress`), Claude starts **5 minutes apart**.
   - When phase 6 is complete, report release readiness for owner action (§8).
   - Write a compact state report (phase, issues, PRs, `.agent/state/` handoffs) for the steps below.
2. **Sonnet** (`claude-sonnet-5-5`, max **40 turns**) runs **only when needed**:
   - the current phase hasn't been opened yet, its predecessor's exit criteria pass, and no planning issue is open; or
   - issues in the current phase lack `model:` / `agent:` labels.

   It opens the phase's issues from `docs/phases/phase-N.md` and then runs `phase.sh mark-opened N`. If that file doesn't exist, it opens one `phase-plan` issue for the architect. It cannot merge, close, or touch owner-only labels; its tools are limited to issue commands and `phase.sh`.
3. **Haiku** (`claude-haiku-5-5`, max 8 turns) posts one summary comment on the pinned **Autopilot log** issue. The log issue is created and pinned on the first run. If the summary step fails, the raw log is posted instead.

**Phases** follow the milestones `Phase N: …`. A phase is complete when its milestone description contains `[opened]`, it has issues (`phase-plan` issues don't count), and none of them are open. The current phase is the lowest incomplete one. Opening phase N+1 also requires the latest `nightly-health` run on `main` to be green.

## 2. `cross-review` status

The status passes only if **the other model reviewed the PR's head commit** and nothing blocking is unresolved:

| PR written by | Who reviews | Counts as reviewed | Blocking |
|---|---|---|---|
| Claude (`agent/<claude agent>/…`, `agent/orchestrator/…`) | Codex | A Codex review on the head commit, or Codex's summary comment showing **Completed** for it | Unresolved Codex threads marked P0 or P1 |
| Codex (`codex/…` or a `model:codex` issue) | Claude (`agent-dispatch` mode=review) | The `<!-- claude-review sha=… verdict=pass run=… -->` marker, posted by that job. Its run id is checked, so nothing else can fake it | Unresolved Claude threads starting with `[blocking]`, or verdict `fail` |
| Owner (`human/…`) | Either | Either of the above | Either |

The authoring model comes from the branch name, or from the linked issue's `model:` label. If it can't be determined, the status fails. The `needs-decision` label (models disagree, CONVENTIONS) also fails it until the owner decides.

"Reviewed" for Codex means its `codex-review-state` block names the head commit as `completed`. If that block reports findings, Codex's review object for the head must also exist, because the "Completed" summary can arrive before its P1 threads (#65). Threads that are *outdated* (their lines changed since) don't block a head the reviewer has re-reviewed. In legacy mode, once `cross-review` passes and CI is green, the merge gate (`gates.sh`, `resolve_settled`) resolves that reviewer's settled threads before hard-stop and owner-gate checks, including on PRs left for owner merge: outdated ones, and open non-blocking ones (Codex P2/P3, Claude threads without `[blocking]`). It replies to each non-blocking thread first, saying why it was resolved and that it can be reopened. Threads opened by anyone else are never touched, and the fixer never resolves its reviewer's threads. This is why GitHub's required conversation resolution (§3) doesn't hold up a green PR over findings that never blocked it. Codex-local never replies to or resolves threads; all unresolved conversations hold its merge.

Reviews are requested once per commit: when a PR is opened or marked ready, and again after CI goes green on a new commit. That saves Codex quota compared with reviewing every push. Turn off Codex's own automatic reviews in Codex settings, or each Claude PR gets reviewed twice.

## 3. Merging, branch protection, owner approval

In legacy mode, an ordinary PR merges (squash, branch deleted) only when **all** of these hold for its head commit. Hard-stop PRs are left for owner merge even after approval:

- `lint`, `build-iso` and `boot-test` passed;
- `cross-review` passes;
- `owner-gate` passes;
- the PR is open, not a draft, and mergeable.

`cross-review.yml` and `fix-on-failure.yml` merge as soon as that's true; the orchestrator catches anything they missed.

**Push workflows after an autopilot merge.** Autopilot merges with `GITHUB_TOKEN`, and GitHub starts no workflow runs for events that token causes, so the merge commit gets no `lint` or `merge-audit` push run (#48 → `a3c177a` had none). `GITHUB_TOKEN` may still dispatch workflows, so `gates.sh` does that: it runs `lint.yml` and `merge-audit.yml` on `main` with `-f sha=<merge commit>`. Both workflows take a `sha` input (`lint` checks it out; `merge-audit` audits `inputs.sha || github.sha`), and a merge-audit run is named `merge-audit <sha>`.

- `gates.sh merge` dispatches right away if the PR is already merged after `gh pr merge`.
- With branch protection the merge is `--auto` and usually lands later, in no run of ours. Every orchestrator run calls `gates.sh push-workflows`, which goes through the last 20 PRs merged by `github-actions` and dispatches for any merge commit that has no `merge-audit <sha>` run. The merge's own issue close doesn't start the orchestrator (same token), so the gap can be one orchestrator interval (up to 3 h).
- A dispatched run belongs to `main`'s tip at dispatch time, so in the Actions list it can show a later commit. The run name and the `sha` input give the audited commit.

**`owner-gate`** fails for any PR that is a hard stop (§7) until the owner approves the head commit. Approval means either the owner's GitHub review approval on that commit, or the label `owner-approved` applied **by the owner** after that commit was pushed. Any new push removes the label.

Every automatic documentation merge in codex-local mode additionally requires `owner-approved`
applied by the owner after the current head commit was pushed (§11).

**Branch protection:** the 2026-10-29 audit recorded `lint`, `build-iso`, `boot-test`,
`cross-review` and `owner-gate` as required Actions checks, admin enforcement and **all review
threads resolved** (`required_conversation_resolution`). This includes decision and ADR PRs.
Required approvals were zero because local PRs use the owner's account and GitHub disallows
self-approval; the separate `owner-gate` status enforces owner approval for sensitive PRs.
The audited up-to-date setting was **false**, contrary to older documentation. Codex-local
holds merges until the owner strengthens it to true; legacy keeps main's behavior.
`scripts/autopilot/protect-main.sh` configures the five checks, up-to-date branches, resolved
conversations, admin enforcement, zero approvals and auto-merge. Inspect existing protection
before using it: do not replace unrelated rules. No protection is changed by this PR.

## 4. fix-on-failure

When `lint` or `build-iso` fails on the **head commit** of a Claude or Codex PR:

- The CI summary (`scripts/ci-summary.sh`, under 2 KB) goes back to the authoring model. Claude gets a `mode=fix` run on the PR branch (Sonnet, 25 turns); Codex gets an `@codex fix …` comment.
- There is at most one retry per commit and **2 per PR**. After that the PR gets `needs-human` and a comment mentioning the owner, which triggers a GitHub notification. Autopilot then leaves it alone until the label is removed.
- MISSION §10 says one retry; the owner raised it to two on 2026-10-16.
- **Blocking review comments** get the same treatment, with their own counter (`fix-retry.sh --review`). When a PR's checks are green and `cross-review` fails only because of unresolved Codex P0/P1 or Claude `[blocking]` comments, the comments go back to the authoring model: a Claude `mode=fix` run, or an `@codex` comment. That's at most one round per commit and 2 per PR, then `needs-human`.

## 5. nightly-health

`build-iso` (which includes `boot-test`) runs on `main` every night. On failure, one issue `fix(ci): nightly health failure on main` is opened with labels `ready`, `priority:high`, `nightly-health`, `agent:ci-engineer` and `model:claude`. Later failures add a comment to it instead of opening another.

A failed or skipped nightly build is not evidence of a successful build and cannot satisfy phase exit criteria.

## 6. resume

Every 2 hours, `paused` issues (set by an agent that ran out of turns or hit a usage limit) are re-dispatched oldest-first within the same caps and stagger. The agent picks up from `.agent/state/<issue>.md`. Paused and needs-human issues hold no
in-progress slot. After three pauses without new commits, dispatch labels the issue
`needs-human` and pings the owner. New commits allow progress; an owner clearing
`needs-human` resets the pause count. Codex-local holds legacy resume entirely.

## 7. Hard stops (autopilot never bypasses)

`installer-disk` is no longer a hard stop (owner, 2026-10-19). In legacy mode, those PRs merge like any other once the checks and cross-review pass;
codex-local excludes them from its automatic lane. They're still authored and reviewed by Opus, and the disk-safety rules in CONVENTIONS still apply. `HARD_STOP_LABELS` (`AUTOPILOT_HARD_STOP_LABELS`) is now empty but kept, so a label can be made a hard stop again; a label counts if it's on the PR now, was ever applied to it, or is on the linked issue.

| Hard stop | How it's enforced |
|---|---|
| Workflow changes (`.github/workflows/`) and the gate code itself (`scripts/autopilot/`) | Path rule; agent prompts forbid editing them. `GITHUB_TOKEN` can't push workflow files anyway |
| Signing keys and secrets (`security/keys/`, `*secret*`, `*minisign*`, `*.key`, `*.pem`, `*.minisig`) | Path rule. Signing secrets are only read by `release.yml` |
| Phase 6 manual gate | The owner opens/conducts the checklist issue; autopilot only reports readiness and stops. Phase 7 opens only after the owner closes it **and** tags `v1.0.0` |
| Final `v1.0.0` tag | All RC and final tags are owner actions; `release.yml` refuses a final tag unless the owner pushed it |

For a hard-stop PR whose automated gates all pass, autopilot comments once per commit, mentioning the owner, and leaves the merge to them.

`decision` PRs and ADR changes (`docs/adr/`) are not hard stops (owner decision, 2026-10-17). They merge like any other PR once CI and cross-review pass and every review thread is resolved. Unattended agents still may not edit `docs/adr/` (agent-dispatch prompt), so ADRs come only from interactive sessions.

## 8. Release

When phase 6 is complete and nightly-health is green, autopilot reports readiness.
**Phase 6 RC tagging and the manual gate are owner actions.** The owner:

1. creates `v1.0.0-rc.N` on reviewed `main` and starts the existing release procedure;
2. invokes `release.yml` on that tag to build both ISOs, write `SHA256SUMS`, sign with the
   release-environment minisign key (ADR-0007), and publish a pre-release (an RC without
   the key is published unsigned with a warning);
3. opens the **Manual gate: v1.0.0-rc.N** issue with the MISSION §14 checklist and labels
   `manual-gate` and `decision`, conducts the tests and records the evidence.

The final `v1.0.0` is also tagged by the owner. Phase 7 opens only after the owner closes
the manual gate and tags `v1.0.0`. `report.sh release-rc` refuses publication and creates
no tags, workflow dispatches, signatures, releases or checklist issues. The owner-invoked
release workflow and signing environment remain unchanged.

## 9. Kill switch

`vars.AUTOPILOT == 'on'` is checked at job level in `orchestrator`, `cross-review`, `agent-dispatch`, `fix-on-failure`, `nightly-health`, `resume`, `release` and `claude`. Turning it off stops new work immediately. Runs already in progress finish their current step; cancel them from the Actions tab if needed.

**Deviation from the spec:** `lint`, `build-iso` and `boot-test` ignore the kill switch. A skipped required check reads as passed to GitHub, so skipping them would be unsafe. They only report results; they never act.

## 10. Guards

- **Turn caps per run:**

  | Run | Cap |
  |---|---|
  | Orchestrator, Sonnet step | 40 |
  | Summary (Haiku) | 8 |
  | Implement | the issue's budget: small 15 / medium 40 / large 80 |
  | Fix | 25 |
  | Review | 20 |

  Every job has a `timeout-minutes`.
- **Model tiers:** an agent runs on the model in its `.claude/agents/*.md` frontmatter. `installer-disk` work and its reviews use Opus. Other reviews and fixes use Sonnet (MISSION §11).
- **Tokens:** the owner token `CODEX_TRIGGER_TOKEN` is given only to deterministic steps (posting `@codex` comments). No LLM step ever sees it, so no LLM can act as the owner, for example by adding `owner-approved`.
- **Gate code comes from `main`:** `cross-review` and `request-review` run on `pull_request_target` and check out the default branch, never the PR. Changes to `scripts/autopilot/` and `.github/workflows/` need the owner's approval.
- **Allowed tools:** every Claude run gets an explicit `--allowedTools` list (no `gh pr merge`, no label edits on PRs).
- **Issue, PR and log text is data:** every prompt says so.

**Residual risk:** a same-repo PR can change a `pull_request` / `pull_request_review` workflow, and that changed workflow runs before review. Required owner approval stops it from merging, not from running. Keep the runner set small and restrict its credentials and access (D9).

## Secrets and variables

| Name | Kind | Used by |
|---|---|---|
| `AUTOPILOT` | variable | Kill switch (`on` to run) |
| `AUTOPILOT_CONTROLLER` | variable | Unset/empty/`legacy` retains legacy workers; `codex-local` selects the opt-in controller (§11) |
| `GEMINI_API_KEY` | private local environment | Bounded local Gemini worker only; never passed to Claude or stored in repo text |
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | All `claude-code-action` steps (set by `/install-github-app`) |
| `CODEX_TRIGGER_TOKEN` | secret | Owner fine-grained PAT, Pull requests read/write: `@codex` comments only |
| `MINISIGN_SECRET_KEY`, `MINISIGN_PASSWORD` | secrets in the `release` environment | `release.yml` publish job only (Phase 5). Required reviewers on an environment need GitHub Pro for a private repo |

## Turning it on

1. Merge reviewed automation changes through the existing CI and owner-merge process.
2. Inspect current branch protection and preserve unrelated rules; do not weaken it.
3. In Codex settings, turn off automatic PR reviews (§2).
4. For legacy mode, retain an unset/empty or `legacy` controller variable, set
   `gh variable set AUTOPILOT --body on`, run **orchestrator** once by hand from the Actions
   tab and read the Autopilot log. Codex-local has separate rollout prerequisites (§11).

## Verify on the first live runs

These couldn't be tested before the workflows were on `main`:

- PRs opened by `claude-code-action` trigger CI. This depends on the action's app token being what `gh pr create` uses.
- Codex responds to `@codex` task comments on issues; otherwise the issue gets `needs-human` (D8).
- The minisign password is accepted from stdin in `release.yml` (Phase 5).

## 11. Codex-local controller addition

The proposed codex-local implementation and rollout procedure are in
[Codex-led autonomous development](AUTONOMY.md). Governance changes to rule 9 and agent
ownership are in PR #295, not accepted policy on main. **Do not enable
codex-local until PR #295 is accepted.** This document describes the Actions
integration and both merge paths. `AUTOPILOT=on` is the kill switch for new work; required CI still reports its real
results when automation is disabled. No activation or protection setting is changed by issue #292.

### Modes and workflows

With `AUTOPILOT_CONTROLLER=codex-local`, legacy implementation, automatic fixes, paused-task
resume and Claude phase planning are held. The bounded local controller owns task selection.
Existing independent cross-model review and required CI remain active. The controller waits
for old Actions workers and in-progress cloud tasks to drain before creating work.

Without that opt-in, legacy dispatch retains its existing three Claude/one Codex issue cap,
five-minute Claude stagger, task turn budgets, two fix retries and three-pause limit. Those
legacy workers do not gain Gemini routing or permission to modify policy. Legacy merges
retain main's existing behavior; only codex-local merges use the stricter live-evidence policy.
Actions passes `AUTOPILOT_CONTROLLER` into `AUTOPILOT_CONTROLLER_MODE`. An unset, empty or
`legacy` merge mode selects legacy behavior; any unknown mode refuses to merge.

| Workflow | Purpose |
|---|---|
| `orchestrator.yml` | Deterministic gate/status sweep, ready labels, legacy dispatch, phase state; legacy model planning/summary only outside Codex mode |
| `cross-review.yml` | Existing cross-review and owner-gate statuses; attempts merges through the selected mode |
| `agent-dispatch.yml` | Legacy implementation/fixes; independent Claude exact-head review; requests other-model review |
| `fix-on-failure.yml` | Legacy bounded fixes outside Codex mode; on success requests review or attempts a merge through the selected mode |
| `resume.yml` | Legacy paused issue dispatch outside Codex mode |
| `nightly-health.yml` | Existing build/boot health checks and deduplicated failure issue |
| `release.yml` | Separately invoked owner release procedure; never invoked by the orchestrator |

Orchestrator and resume retain the shared Actions concurrency group. The local controller has
an additional repository-wide atomic lease and private state lock. They are separate systems;
the rollout must reconcile old workers first.

### Reviews and merges

Claude-authored PRs require independent Codex review. Codex/Gemini PRs require the trusted
Claude review job. The job captures an immutable base/head diff, records the full head SHA,
and refuses a pass marker if the head moved or the model action failed. No merge path
creates a GitHub approval. Required formal approvals still need independent actors.
Failed or incomplete reviews are re-requested within the existing bounded request limits.

Both modes retain the existing checks, cross-review, hard stops and owner gate. Workflow,
autopilot, merge-guard and signing-material hard stops are left for owner approval and owner
merge; approval does not bypass them. See `CONVENTIONS.md` for the existing installer safety
and owner-approval requirements.

In **legacy mode**, the gate restores main's `resolve_settled` behavior: after a clean review
of the head and before hard-stop/owner-gate checks, it resolves that reviewer's outdated and non-blocking threads, replying to live
non-blocking threads first. It checks `protected()` and uses
`gh pr merge --auto --squash --delete-branch` for protected main. For unprotected main it uses
`--squash --delete-branch --match-head-commit <head>`. The legacy path does not call policy.py
and is not limited to documentation. Existing installer-disk requirements remain in force.

In **codex-local mode**, only ordinary user-documentation/CHANGELOG PRs can enter unattended
merge. Existing text must remain an exact byte-for-byte prefix; only appends and new files
are eligible. Every automatic merge requires the `owner-approved` label applied **by the
owner** after the current head commit was pushed. The policy verifies the label's actor and
timing for that head; each new head requires the owner to reapply it. An approving review alone
does not satisfy this requirement. This owner consent is additional to independent review
and all required checks. Unreadable text holds the lane. Disk-installer, security, signing,
release and decision work stays outside this automatic lane.

The codex-local policy independently verifies immutable Git blobs, PR/head/run-attempt-bound
Claude review receipts and all existing required GitHub rules. A passing cross-review status
alone is insufficient: every unresolved thread, including outdated and P2 threads, holds the
merge. This path never replies to or resolves threads on behalf of a reviewer. A policy
refusal posts one deduplicated comment per head with the reason.

`main` audited on 2026-10-29 requires `lint`, `build-iso`, `boot-test`, `cross-review`, and
`owner-gate` from GitHub Actions, admin enforcement and resolved conversations. Required
approvals are currently zero; this does not authorize self-approval. The actual up-to-date
setting is **false**, contrary to older documentation. Codex-local merges remain held until
an owner strengthens it to true. Legacy merges retain their existing behavior. No protections
are weakened or rewritten automatically.

Codex-local merges are immediate squash requests pinned to the checked full head, with no
`--auto` queue, branch deletion or unprotected fallback. The local controller explicitly
selects this mode after verifying live activation switches. After a confirmed merge in either
mode, `gates.sh push-workflows` starts missing lint/merge-audit evidence for the merge commit,
because `GITHUB_TOKEN` events may not trigger push workflows. Its sweep also catches legacy
`--auto` merges that complete later. Deduplication captures run listings before matching them,
avoiding a pipefail/SIGPIPE loop. Existing recovery branches and worktrees are never deleted.

### Releases and stop controls

The orchestrator reports release readiness for owner action. `report.sh release-rc` refuses
publication: it creates no tag, signature, release or release-workflow dispatch. The existing
owner-invoked release workflow and signing environment remain unchanged. Phase 6 RC tagging
and the manual gate are now owner actions: the owner creates the RC tag, starts publication
and conducts/records the manual gate. Autopilot only reports readiness.

Set `AUTOPILOT` to anything except `on` to stop new automatic work. Cancel in-flight Actions
and terminate a local cycle if an immediate stop is needed. Preserve the controller state,
checkouts and lease for inspection. Unknown controller modes and failed mode reads stop
legacy dispatch instead of silently falling back. Full recovery and first-live-run acceptance
steps are in [AUTONOMY.md](AUTONOMY.md).
