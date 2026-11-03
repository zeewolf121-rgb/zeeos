# ADR-0013: Bounded Codex-led autonomous development

- Status: **Accepted**; merged in PR #295 on 2026-11-03 after independent cross-review and resolved threads.
- Date: 2026-10-31
- Deciders: owner-directed issue #292; Codex integration; independent Claude review.

## Context

The owner requested Codex orchestration with Gemini and Claude implementing/reviewing bounded
tasks, and automatic merging of successful eligible PRs. Issue #292 explicitly assigns the
CI-engineer tooling/workflow scope and Codex shared-context/documentation integration. This is
an interactive implementation of that issue, not permission for unattended agents to edit
workflows or expand their write scopes. Existing progress and recovery work must survive.

## Options

1. Keep only legacy Actions workers. This does not provide the requested bounded Gemini lane.
2. Let model agents execute arbitrary tools and approve/merge their own output. Reject: this
   violates independent review, permission and resource requirements.
3. Use a deterministic controller with bounded proposals and an independent live merge guard.

## Decision

Adopt option 3, as specified in `../AUTONOMY.md`. Codex integrates policy and permissions;
provider agents return scoped JSON without tools, hooks, GitHub or signing credentials.
Durable leases, budgets, attempt caps and private audit metadata bound execution. The initial
lane permits only new documentation files or byte-preserving appends to existing files.

An independent model reviews the exact PR head. Existing required GitHub reviews/checks and
all live protections remain mandatory. Claude Actions review authority requires a trusted
PR/head/run-attempt receipt rather than model-written summary text. There is no self-approval,
protection bypass, thread resolution on behalf of reviewers, or automatic signed publication.

This records the rule-9/shared-context clarification and generated AGENTS.md/CLAUDE.md changes;
it does not grant broader unattended scopes. Accepted ADR-0008 package refresh/boot-chain rules,
ADR-0007 signing requirements, and installer safety requirements remain in force. Automation,
workflow and merge-guard changes retain owner approval and owner merge under CONVENTIONS.
That requirement comes from the sensitive implementation files in this PR, not from ADR
acceptance itself: ADRs follow the cross-review/merge rule in `README.md` without a separate
owner approval requirement. Acceptance does not authorize rollout before the conditions in
`../AUTONOMY.md` are met.

## Owner decision on governance scope

On 2026-11-01, the [owner decision on PR #293](https://github.com/zeewolf121-rgb/zeeos/pull/293#issuecomment-6562664361)
accepted the hard rule 9 and agent-ownership changes and ADR-0013 as written and in scope
for this PR, settling the governance scope dispute. This decision is not owner-gate approval
of any commit. This ADR became **Accepted** when PR #295 merged on 2026-11-03 after
independent cross-review with all review threads resolved, as specified in `README.md`.

## Consequences

Useful low-risk work can proceed without routine human confirmations after reviewed rollout.
Unsupported protection, missing/stale/ambiguous evidence, sensitive work, exhausted budgets or
provider errors hold work. Rewriting existing guides requires the stronger owner lane, even
when a model considers the rewrite safe. Provider canaries and a real protected low-risk merge
must establish rollout readiness; mocked tests alone cannot do so. No activation is included.

## What would flip this decision

A provider cannot honor the bounds, deterministic checks cannot establish review provenance,
or live branch protection cannot enforce the required guarantees: keep the lane disabled and
propose a separately reviewed replacement. Broader scopes require their own policy change.
