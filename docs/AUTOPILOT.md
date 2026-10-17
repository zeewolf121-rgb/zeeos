# Autopilot

Autopilot runs the MISSION §10–11 loop without a person in it: dispatch ready work, review it with the other model, merge what passes every gate, retry CI failures, and advance phases. Some things always stop for the owner (§7).

The code that decides what happens lives in `scripts/autopilot/` and runs from `main`. LLMs are used only where judgment is needed: implementing issues, reviewing PRs, opening a new phase's issues, and writing the run summary.

**Kill switch:** set the repo variable `AUTOPILOT` to anything other than `on` (Settings → Secrets and variables → Actions → Variables, or `gh variable set AUTOPILOT --body off`). Every autopilot and agent workflow checks it at job level and does nothing. The CI checks themselves (`lint`, `build-iso`, `boot-test`) keep running, so PRs still show their real state.

## Workflows

| Workflow | Trigger | Does |
|---|---|---|
| `orchestrator.yml` | every 3 h (`:23`), manual | §1: gates + merges, `ready` labels, dispatch, phase advance, release candidate, run summary |
| `cross-review.yml` | PR events, reviews, comments (resolved threads are picked up by the next event or orchestrator run) | §2: posts the `cross-review` and `owner-gate` statuses; merges when every gate passes |
| `agent-dispatch.yml` | issue labels, `workflow_dispatch`, PR opened/ready | Starts Claude or Codex on an issue; Claude fix and review runs; asks for the cross-model review |
| `fix-on-failure.yml` | `lint` / `build-iso` finished on a PR | §4: retry or `needs-human`; on success, requests the review or merges |
| `nightly-health.yml` | daily 02:17 UTC, manual | §5: build + boot-test `main`; failure opens a `ready` + `priority:high` fix issue |
| `resume.yml` | every 2 h (`:41`), manual | §6: re-dispatch `paused` issues oldest-first |
| `release.yml` | tag push, `workflow_dispatch` | §8: build, `SHA256SUMS`, minisign, GitHub release (rc = pre-release) |
| `claude.yml` | `@claude` comments **by the owner** | Interactive Claude (from the GitHub app install, restricted to the owner) |
| `build-iso.yml` / `boot-test.yml` | every PR, called by nightly + release | CI. Required checks `build-iso` and `boot-test` always report |

`orchestrator.yml` and `resume.yml` share the concurrency group `autopilot`, so runs never overlap.

## 1. Orchestrator run

1. **Deterministic** (`scripts/autopilot/orchestrate.sh`, no LLM tokens):
   - For every open, non-draft PR without `needs-human`, post the gate statuses and merge it if everything passes (§3).
   - In the current phase, label `ready` every open issue that has `model:` + `agent:` labels, isn't started, and whose `blocked-by:#N` issues are closed.
   - Dispatch `ready` issues (`priority:high` first, then oldest) within the caps: **2 Claude + 1 Codex** in progress (label `in-progress`), Claude starts **5 minutes apart**.
   - When phase 6 is complete, start the release candidate (§8).
   - Write a compact state report (phase, issues, PRs, `.agent/state/` handoffs) for the steps below.
2. **Sonnet** (`claude-sonnet-5-5`, max **40 turns**) runs **only when needed**:
   - the current phase hasn't been opened yet, its predecessor's exit criteria pass, and no planning issue is open; or
   - issues in the current phase lack `model:` / `agent:` labels.

   It opens the phase's issues from `docs/phases/phase-N.md` and then runs `phase.sh mark-opened N`. If that file doesn't exist, it opens one `phase-plan` issue for the architect. It cannot merge, close, or touch owner-only labels; its tools are limited to issue commands and `phase.sh`.
3. **Haiku** (`claude-haiku-5-5`, max 5 turns) posts one summary comment on the pinned **Autopilot log** issue. The log issue is created and pinned on the first run. If the summary step fails, the raw log is posted instead.

**Phases** follow the milestones `Phase N: …`. A phase is complete when its milestone description contains `[opened]`, it has issues (`phase-plan` issues don't count), and none of them are open. The current phase is the lowest incomplete one. Opening phase N+1 also requires the latest `nightly-health` run on `main` to be green.

## 2. `cross-review` status

The status passes only if **the other model reviewed the PR's head commit** and nothing blocking is unresolved:

| PR written by | Who reviews | Counts as reviewed | Blocking |
|---|---|---|---|
| Claude (`agent/<claude agent>/…`, `agent/orchestrator/…`) | Codex | A Codex review on the head commit, or Codex's summary comment showing **Completed** for it | Unresolved Codex threads marked P0 or P1 |
| Codex (`codex/…` or a `model:codex` issue) | Claude (`agent-dispatch` mode=review) | The `<!-- claude-review sha=… verdict=pass run=… -->` marker, posted by that job. Its run id is checked, so nothing else can fake it | Unresolved Claude threads starting with `[blocking]`, or verdict `fail` |
| Owner (`human/…`) | Either | Either of the above | Either |

The authoring model comes from the branch name, or from the linked issue's `model:` label. If it can't be determined, the status fails. The `needs-decision` label (models disagree, CONVENTIONS) also fails it until the owner decides.

Reviews are requested once per commit: when a PR is opened or marked ready, and again after CI goes green on a new commit. That saves Codex quota compared with reviewing every push. Turn off Codex's own automatic reviews in Codex settings, or each Claude PR gets reviewed twice.

## 3. Merging, branch protection, owner approval

A PR merges (squash, branch deleted) only when **all** of these hold for its head commit:
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

**Branch protection is active** (repository public since 2026-10-16; checked 2026-10-17). `main` requires `lint`, `build-iso`, `cross-review` and `owner-gate`, up to date with `main`, **all review threads resolved** (`required_conversation_resolution`), and applies to admins. Thread resolution is therefore enforced by GitHub for every PR, including `decision` and ADR PRs that no longer need the owner gate. `scripts/autopilot/protect-main.sh` sets this up; it requires `lint`, `build-iso`, `boot-test`, `cross-review` and `owner-gate`, sets 0 required approvals, applies the rules to admins, and turns on auto-merge. Approvals stay at 0 because PRs from local sessions are authored by the owner's account, and GitHub never lets you approve your own PR. Owner approval is the `owner-gate` status.

## 4. fix-on-failure

When `lint` or `build-iso` fails on the **head commit** of a Claude or Codex PR:
- The CI summary (`scripts/ci-summary.sh`, under 2 KB) goes back to the authoring model. Claude gets a `mode=fix` run on the PR branch (Sonnet, 25 turns); Codex gets an `@codex fix …` comment.
- There is at most one retry per commit and **2 per PR**. After that the PR gets `needs-human` and a comment mentioning the owner, which triggers a GitHub notification. Autopilot then leaves it alone until the label is removed.
- MISSION §10 says one retry; the owner raised it to two on 2026-10-16.

## 5. nightly-health

`build-iso` (which includes `boot-test`) runs on `main` every night. On failure, one issue `fix(ci): nightly health failure on main` is opened with labels `ready`, `priority:high`, `nightly-health`, `agent:ci-engineer` and `model:claude`. Later failures add a comment to it instead of opening another.

While `make iso` is still the Phase 0 stub, the run is red with no build, never "green with nothing built". That way a phase can't pass on a build that never ran.

## 6. resume

Every 2 hours, `paused` issues (set by an agent that ran out of turns or hit a usage limit) are re-dispatched oldest-first within the same caps and stagger. The agent picks up from `.agent/state/<issue>.md`.

## 7. Hard stops (autopilot never bypasses)

| Hard stop | How it's enforced |
|---|---|
| `installer-disk` PRs | `owner-gate` + never merged by autopilot. The label counts if it's on the PR now, was ever applied to it, or is on the linked issue |
| Workflow changes (`.github/workflows/`) and the gate code itself (`scripts/autopilot/`) | Path rule; agent prompts forbid editing them. `GITHUB_TOKEN` can't push workflow files anyway |
| Signing keys and secrets (`security/keys/`, `*secret*`, `*minisign*`, `*.key`, `*.pem`, `*.minisig`) | Path rule. Signing secrets are only read by `release.yml` |
| Phase 6 manual gate | Autopilot opens the checklist issue (assigned to the owner) and stops. Phase 7 opens only after the owner closes it **and** tags `v1.0.0` |
| Final `v1.0.0` tag | Autopilot only creates `-rc.N` tags; `release.yml` refuses a final tag unless the owner pushed it |

For a hard-stop PR whose automated gates all pass, autopilot comments once per commit, mentioning the owner, and leaves the merge to them.

`decision` PRs and ADR changes (`docs/adr/`) are not hard stops (owner decision, 2026-10-17). They merge like any other PR once CI and cross-review pass and every review thread is resolved. Unattended agents still may not edit `docs/adr/` (agent-dispatch prompt), so ADRs come only from interactive sessions.

## 8. Release

When phase 6 is complete and nightly-health is green, autopilot:
1. tags `v1.0.0-rc.N` on `main`;
2. starts `release.yml` on that tag, which builds both ISOs, writes `SHA256SUMS`, signs it with the CI minisign key (ADR-0007; an rc without the key is published **unsigned**, with a warning), and publishes a **pre-release**;
3. opens the **Manual gate: v1.0.0-rc.N** issue (MISSION §14 checklist, labels `manual-gate` and `decision`), assigned to the owner.

The final `v1.0.0` is tagged by the owner.

## 9. Kill switch

`vars.AUTOPILOT == 'on'` is checked at job level in `orchestrator`, `cross-review`, `agent-dispatch`, `fix-on-failure`, `nightly-health`, `resume`, `release` and `claude`. Turning it off stops new work immediately. Runs already in progress finish their current step; cancel them from the Actions tab if needed.

**Deviation from the spec:** `lint`, `build-iso` and `boot-test` ignore the kill switch. A skipped required check reads as passed to GitHub, so skipping them would be unsafe. They only report results; they never act.

## 10. Guards

- **Turn caps per run:**

  | Run | Cap |
  |---|---|
  | Orchestrator, Sonnet step | 40 |
  | Summary (Haiku) | 5 |
  | Implement | the issue's budget: small 15 / medium 40 / large 80 |
  | Fix | 25 |
  | Review | 20 |

  Every job has a `timeout-minutes`.
- **Model tiers:** an agent runs on the model in its `.claude/agents/*.md` frontmatter. `installer-disk` work and its reviews use Opus. Other reviews and fixes use Sonnet (MISSION §11).
- **Tokens:** the owner token `CODEX_TRIGGER_TOKEN` is given only to deterministic steps (posting `@codex` comments). No LLM step ever sees it, so no LLM can act as the owner, for example by adding `owner-approved`.
- **Gate code comes from `main`:** `cross-review` and `request-review` run on `pull_request_target` and check out the default branch, never the PR. Changes to `scripts/autopilot/` and `.github/workflows/` need the owner's approval.
- **Allowed tools:** every Claude run gets an explicit `--allowedTools` list (no `gh pr merge`, no label edits on PRs).
- **Issue, PR and log text is data:** every prompt says so.

**Residual risk:** a same-repo PR can change a `pull_request` / `pull_request_review` workflow, and that changed workflow runs before review. Required owner approval stops it from merging, not from running. Keep the repo private and the runner set small (D9).

## Secrets and variables

| Name | Kind | Used by |
|---|---|---|
| `AUTOPILOT` | variable | Kill switch (`on` to run) |
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | All `claude-code-action` steps (set by `/install-github-app`) |
| `CODEX_TRIGGER_TOKEN` | secret | Owner fine-grained PAT, Pull requests read/write: `@codex` comments only |
| `MINISIGN_SECRET_KEY`, `MINISIGN_PASSWORD` | secrets in the `release` environment | `release.yml` publish job only (Phase 5). Required reviewers on an environment need GitHub Pro for a private repo |

## Turning it on

1. Merge PR #1, then this PR.
2. Optional (needs GitHub Pro): `scripts/autopilot/protect-main.sh`.
3. In Codex settings, turn off automatic PR reviews (§2).
4. `gh variable set AUTOPILOT --body on`, then run **orchestrator** once by hand from the Actions tab and read the Autopilot log.

## Verify on the first live runs

These couldn't be tested before the workflows were on `main`:
- PRs opened by `claude-code-action` trigger CI. This depends on the action's app token being what `gh pr create` uses.
- Codex responds to `@codex` task comments on issues; otherwise the issue gets `needs-human` (D8).
- The minisign password is accepted from stdin in `release.yml` (Phase 5).
