# Autopilot

Codex owns orchestration. The reviewed policy and rollout procedure are in
[Codex-led autonomous development](AUTONOMY.md). This document describes the existing Actions
integration. `AUTOPILOT=on` is the kill switch for new work; required CI still reports its real
results when automation is disabled. No activation or protection setting is changed by issue #292.

## Modes and workflows

With `AUTOPILOT_CONTROLLER=codex-local`, legacy implementation, automatic fixes, paused-task
resume and Claude phase planning are held. The bounded local controller owns task selection.
Existing independent cross-model review and required CI remain active. The controller waits
for old Actions workers and in-progress cloud tasks to drain before creating work.

Without that opt-in, legacy dispatch retains its existing three Claude/one Codex issue cap,
five-minute Claude stagger, task turn budgets, two fix retries and three-pause limit. Those
legacy workers do not gain Gemini routing or permission to modify policy. All merge attempts,
in either mode, now pass the same conservative live-evidence policy.

| Workflow | Purpose |
|---|---|
| `orchestrator.yml` | Deterministic gate/status sweep, ready labels, legacy dispatch, phase state; legacy model planning/summary only outside Codex mode |
| `cross-review.yml` | Existing cross-review and owner-gate statuses; attempts policy-governed merges |
| `agent-dispatch.yml` | Legacy implementation/fixes; independent Claude exact-head review; requests other-model review |
| `fix-on-failure.yml` | Legacy bounded fixes outside Codex mode; on success requests review or attempts a policy merge |
| `resume.yml` | Legacy paused issue dispatch outside Codex mode |
| `nightly-health.yml` | Existing build/boot health checks and deduplicated failure issue |
| `release.yml` | Separately invoked owner release procedure; never invoked by the orchestrator |

Orchestrator and resume retain the shared Actions concurrency group. The local controller has
an additional repository-wide atomic lease and private state lock. They are separate systems;
the rollout must reconcile old workers first.

## Reviews and merges

Claude-authored PRs require independent Codex review. Codex/Gemini PRs require the trusted
Claude review job. The job captures an immutable base/head diff, records the full head SHA,
and refuses a pass marker if the head moved or the model action failed. The deterministic
merge policy independently verifies review provenance and all existing required GitHub rules.
It never creates a GitHub approval. Required formal approvals still need independent actors.

Older cross-review status rules distinguish blocking findings, but a passing status alone
is insufficient to merge: the new policy holds every unresolved thread, including outdated
and P2 threads. It never replies/resolves on behalf of a reviewer. Failed or incomplete reviews
are re-requested within the existing bounded request limits; no label or marker bypasses CI.

Only ordinary user-documentation/CHANGELOG PRs can enter unattended merge. Workflow,
autopilot, merge-guard, disk-installer, security, signing, release and decision work stays in
the stronger owner/specialist lane. Owner approval does not turn sensitive code into low-risk
work. See `CONVENTIONS.md` for the existing installer safety and owner-approval requirements.

`main` audited on 2026-10-29 requires `lint`, `build-iso`, `boot-test`, `cross-review`, and
`owner-gate` from GitHub Actions, admin enforcement and resolved conversations. Required
approvals are currently zero; this does not authorize self-approval. The actual up-to-date
setting is **false**, contrary to older documentation. Automatic merges therefore remain held
until an owner strengthens it to true. No protections are weakened or rewritten automatically.

Merges are immediate squash requests pinned to the checked full head; there is no deferred
`--auto` queue or unprotected fallback. After a confirmed merge, `gates.sh push-workflows`
starts missing lint/merge-audit evidence for the merge commit, because `GITHUB_TOKEN` events
may not trigger push workflows. Its deduplication captures run listings before matching them,
avoiding a pipefail/SIGPIPE loop. Existing recovery branches and worktrees are never deleted.

## Releases and stop controls

The orchestrator reports release readiness for owner action. `report.sh release-rc` refuses
publication: it creates no tag, signature, release or release-workflow dispatch. The existing
owner-invoked release workflow and signing environment remain unchanged.

Set `AUTOPILOT` to anything except `on` to stop new automatic work. Cancel in-flight Actions
and terminate a local cycle if an immediate stop is needed. Preserve the controller state,
checkouts and lease for inspection. Unknown controller modes and failed mode reads stop
legacy dispatch instead of silently falling back. Full recovery and first-live-run acceptance
steps are in [AUTONOMY.md](AUTONOMY.md).
