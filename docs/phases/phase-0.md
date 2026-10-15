# Phase 0: Architecture and repo setup

## Done in this phase (branch `agent/orchestrator/phase-0-scaffold`)

- [x] ADRs 0001–0006 drafted (all **Proposed**)
- [x] `docs/ARCHITECTURE.md`, `docs/CONVENTIONS.md`, `docs/agents.md`
- [x] `CLAUDE.md` / `AGENTS.md` generated from `docs/agent-context.md` by `scripts/sync-agent-docs.sh`
- [x] Claude subagents in `.claude/agents/`
- [x] Directory skeleton with owner READMEs
- [x] `Makefile` with `make iso ARCH=…` entry point
- [x] CI skeleton: 4 workflows (lint, build-iso, boot-test, agent-dispatch), PR and issue templates, CODEOWNERS
- [x] `.github/labels.yml` + `scripts/gh-bootstrap.sh` (labels, Project board; milestones and branch protection come after approval)
- [x] `scripts/ci-summary.sh` and the handoff template `.agent/state/TEMPLATE.md`
- [x] Model tier set in each `.claude/agents/*.md` (MISSION §11)

## Waiting for the owner (STOP)

| # | Decision | Proposal |
|---|---|---|
| D1 | Base distro | Fedora, current stable (ADR-0001) |
| D2 | Build tool | kiwi-ng (ADR-0002) |
| D3 | Installer | Calamares (ADR-0003) |
| D4 | Bootloader | GRUB 2 via signed shim (ADR-0004) |
| D5 | Compositor/desktop | KWin + Plasma 6 (ADR-0005) |
| D6 | Licensing | GPL-3.0+ / CC-BY-SA-4.0 / OFL (ADR-0006) |
| D7 | Repo | Private GitHub repo `zeeos` under account `zeewolf121-rgb` (or an org you choose) |
| D8 | Codex access | **Decided (2026-10-16):** Codex cloud via the GitHub integration. Reviews start with an `@codex review` PR comment, posted by `agent-dispatch.yml` on Claude-authored PRs |

## After approval

1. Merge the Phase 0 PR, then turn on branch protection for `main`.
2. Mark the approved ADRs **Accepted**.
3. Open Phase 1 issues (see `phase-1.md`) and dispatch them.
