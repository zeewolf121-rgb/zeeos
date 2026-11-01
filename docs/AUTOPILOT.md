# Autopilot

The proposed codex-local implementation and rollout procedure are in
[Codex-led autonomous development](AUTONOMY.md). Governance changes to rule 9 and agent
ownership are in a separate decision PR, not accepted policy on main. **Do not enable
codex-local until that decision PR is accepted.** This document describes the Actions
integration and both merge paths. `AUTOPILOT=on` is the kill switch for new work; required CI still reports its real
results when automation is disabled. No activation or protection setting is changed by issue #292.

## Modes and workflows

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

## Reviews and merges

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
of the head, it resolves that reviewer's outdated and non-blocking threads, replying to live
non-blocking threads first. It checks `protected()` and uses
`gh pr merge --auto --squash --delete-branch` for protected main. For unprotected main it uses
`--squash --delete-branch --match-head-commit <head>`. The legacy path does not call policy.py
and is not limited to documentation. Existing installer-disk requirements remain in force.

In **codex-local mode**, only ordinary user-documentation/CHANGELOG PRs can enter unattended
merge. Existing text must remain an exact byte-for-byte prefix; only appends and new files
are eligible. Both proposal validation and merge policy reject disk-topic paths and additions,
case-insensitively with whole-word matching. The topic list and deliberate substring choices
(`format` blocks; `information` and `reformat` do not) are in [AUTONOMY.md](AUTONOMY.md).
Unreadable text holds the lane. Disk-installer, security, signing, release and decision work
stays outside this automatic lane.

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

## Releases and stop controls

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
