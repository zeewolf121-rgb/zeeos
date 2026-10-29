# Codex-led autonomous development

This policy implements issue #292. Codex owns orchestration and deterministic permissions;
Gemini and Claude are bounded implementation/review agents. An agent's text is untrusted
input, never permission to execute a command, approve a PR, or change policy.

## Eligible work and independent review

The initial unattended implementation lane accepts only open issues labelled `ready`,
`autonomy:low-risk`, exactly one of `model:gemini`/`model:claude`, and `agent:docs-writer`.
Blocked, paused, in-progress, decision, installer-disk, security, release and needs-human
issues are excluded. Only `docs/user/**/*.md` and `CHANGELOG.md` may change: at most three
UTF-8 files, 16 KB each. Models return complete-file JSON; the controller validates paths,
symlinks, size and credential patterns before applying it in a fresh clone.

Gemini proposals receive independent Claude review; Claude proposals receive Gemini review.
That local review is advisory evidence only. After publication, Gemini PRs require the
existing trusted Claude Actions review of the exact full head SHA. Claude PRs retain the
trusted Codex review. No agent submits an approval of its own code. If GitHub requires
formal approvals, independent head approvals must also satisfy the current count. Unsupported
code-owner/last-push rules stop automatic merging rather than being guessed or bypassed.

## Merge authorization

`scripts/autopilot/policy.py check N` is read-only. The merge command collects live evidence
twice, rechecks the kill switch and existing cross-review gate, then requests a squash merge
with `--match-head-commit`. It does not use `--admin`, queue `--auto`, delete branches, approve
reviews, resolve threads, edit protection, or fall back to an unprotected merge.

All of the following must hold:

- Same-repository, open, non-draft PR into current `main`, with the current base included.
- Current protection enforces admins and resolved conversations, disallows force pushes and
  deletion, and requires up-to-date branches (`strict=true`). Every effective rule must be
  understood. The five existing Actions checks remain required: `lint`, `build-iso`,
  `boot-test`, `cross-review`, `owner-gate`. Additional live required checks are enforced too.
- Every required check succeeds on the full head SHA, from its required app. A newer pending,
  failed, skipped or ambiguous result holds the merge. Commit statuses cannot spoof checks.
- Independent full-head model review has verified provenance; all review threads, including
  outdated or low-priority threads, are resolved by the responsible reviewer/owner.
  Outstanding changes-requested reviews and required independent approvals are respected.
- One matching open linked issue, consistent author-model attribution, safe ordinary text
  files only, and no current or historical owner-lane label on either PR or issue.

Live `main` audited 2026-10-29 has `strict=false` despite older documentation claiming it was
up to date. This implementation deliberately holds merges until the owner strengthens that
setting. It does not change branch protection. GitHub remains the final authorization layer;
protection must remain in force throughout the merge operation.

## Sensitive work

Workflow/automation/merge-guard changes still require owner approval and owner merge under
`docs/CONVENTIONS.md`. Installer disk work retains its stronger existing Opus authorship,
independent review, dry-run and installation-test requirements; it is outside this lane.
Security gates, keys, signing and release changes are also outside it. A ready RC is reported
for owner action: the orchestrator never creates release tags or invokes signed publication.
The separately owner-invoked release workflow is unchanged.

## Resource and permission bounds

| Resource | Limit |
|---|---|
| Concurrency | One leased cycle; Codex plus at most two model roles, invoked serially |
| Starts | Two tasks/cycle, five minutes apart; four attempts per UTC day |
| Retries | Two durable attempts per issue; failed attempt immediately becomes needs-human |
| Model call | 180 seconds, 48 KB input, 64 KB captured output; one turn |
| Claude spend | $0.50/call; at most $2/day from four task attempts, plus explicit canaries |
| Gemini output | 4,096 tokens/call; no claimed dollar ceiling (provider pricing varies) |
| Evidence | Bounded pagination; overflow/incomplete evidence holds work |

Local advisory reviews use one call to each provider per attempt. Remote existing PR reviews
have their existing workflow turn/time caps and separate provider billing; the table's dollar
cap covers local Claude calls only. There is no unlimited daemon, automatic agent recursion,
or arbitrary shell interface. The Codex operator can run finite cycles using its own approved
scheduler; no scheduler or activation variable is installed by this change.

Models have no tools, MCP servers or hooks. Gemini uses an isolated configuration and an
administrative wildcard-deny tool policy. Claude uses safe mode, no tools, empty MCP/settings
sources and no persisted session. Only the corresponding provider credential environment is
passed to each CLI; GitHub/signing credentials are never passed to model children. These CLI
controls are application restrictions, not a claim of operating-system sandbox isolation.
Use a dedicated unprivileged provider account/runtime for rollout. Repository text is scanned
for common credential formats, but that scan is not a guarantee against arbitrary secrets.

Use one canonical private 0700 state directory for this repository across every cycle. Budget
and retry accounting is durable within that directory, not global across replacement directories
or hosts; changing/deleting the ledger is not an authorized budget reset. It contains a local lock, durable attempt reservations and a
hash-chained metadata audit. Prompts, outputs and credential diagnostics are not logged.
Checkouts are retained for reconciliation. An atomic Git ref lease prevents concurrent
controllers; it has no automatic expiry/takeover. An interrupted lease requires inspection,
not deletion on a timer. Existing branches/PRs, including closed PRs, are never overwritten
or recreated automatically. An empty-expected-value branch push lease allows creation only.

## Owner rollout and recovery

1. Review this automation PR through the existing independent review/CI process; the owner
   approves and merges it. Do not self-approve the owner-authored PR.
2. Inspect current legacy cloud tasks and running Actions jobs. Finish or explicitly reconcile
   them without discarding work. The controller holds while legacy in-progress agent/model
   issues or dispatch jobs remain. `needs-human` is not evidence that a cloud task stopped.
3. Strengthen current main protection to require up-to-date branches while preserving all
   reviews, checks, admin enforcement and conversation rules. Re-audit live protection;
   do not run a setup script that replaces unrelated existing protection.
4. Authenticate the installed CLIs using the providers' local login/API-key setup. Never paste
   keys into issues, PRs, logs or model task text. Run `team.py canary --state <private-dir>`;
   both providers must pass. Failed authentication is a hold, not a reason to relax tool policy.
5. From a clean checkout of reviewed, current `main`, set `AUTOPILOT_CONTROLLER=codex-local`
   and retain `AUTOPILOT=on`. This disables legacy implementation/fix/resume/planning workers;
   independent review and required CI continue. Create the opt-in label if absent and choose
   one factual documentation issue with acceptance criteria. Run a single `team.py cycle`.
6. Check the journal, PR head, independent remote review and required CI. A real successful
   low-risk merge is the live acceptance criterion. Only then schedule further finite cycles.

To stop new work set `AUTOPILOT` off; terminate a currently running local cycle and cancel any
in-flight Actions runs if immediate stop is required. A running local proposal revalidates
task/base before publishing, and every merge rechecks the switch. Preserve the state directory,
checkouts and lease evidence. Inspect the lease's commit and journal before an owner removes a
stale lease. Keep the controller mode selected while reconciling; switching back to legacy can
restart old workers. Never erase reservations to get more budget or retries.

## Verification and current limits

Offline tests exercise a real temporary Git repository through proposal, independent mock
review, application, commit and mocked publication; adversarial tests cover scopes, provider
permissions, leases, retries, budgets and stale evidence. Merge tests use realistic GitHub
fixtures including pagination, check provenance and changed evidence. Shell integration tests
ensure sensitive work and release publication remain held. These are simulated service tests,
not proof that a real provider reviewed or a protected GitHub PR merged.

During implementation both installed provider canaries failed (Gemini exit 55, Claude exit 1).
No live provider-to-GitHub-to-merge end-to-end success is claimed. Live API evidence confirms
PR #198 merged and PR #283 closed unmerged. The policy PR itself is owner-only and is never
used as a low-risk merge canary. Activation remains off until the rollout conditions above hold.
