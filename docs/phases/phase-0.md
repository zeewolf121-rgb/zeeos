# Phase 0: Architecture and repo setup

## Done in this phase (branch `agent/orchestrator/phase-0-scaffold`)

- [x] ADRs 0001–0007 (all **Accepted** by the owner on 2026-10-16)
- [x] `docs/ARCHITECTURE.md`, `docs/CONVENTIONS.md`, `docs/agents.md`
- [x] `CLAUDE.md` / `AGENTS.md` generated from `docs/agent-context.md` by `scripts/sync-agent-docs.sh`
- [x] Claude subagents in `.claude/agents/`
- [x] Directory skeleton with owner READMEs
- [x] `Makefile` with `make iso ARCH=…` entry point
- [x] CI skeleton: 4 workflows (lint, build-iso, boot-test, agent-dispatch), PR and issue templates, CODEOWNERS
- [x] `.github/labels.yml` + `scripts/gh-bootstrap.sh` (labels, Project board)
- [x] `scripts/ci-summary.sh` and the handoff template `.agent/state/TEMPLATE.md`
- [x] Model tier set in each `.claude/agents/*.md` (MISSION §11)
- [x] Codex review + issue dispatch through `agent-dispatch.yml` (D8)

## Owner decisions (2026-10-16)

| # | Decision | Outcome |
|---|---|---|
| D1 | Base distro | Approved: **Fedora 44**, pinned. Move to N+1 one month after its GA (ADR-0001) |
| D2 | Build tool | Approved: **kiwi-ng**. "Why not mkosi" added to ADR-0002 |
| D3 | Installer | Approved: **Calamares**. Phase 4 issues for the BitLocker-detect and dirty-NTFS-block modules (`installer-disk`) |
| D4 | Bootloader | Approved: **GRUB 2** via Fedora's signed shim + signed GRUB only. Config-level theming, no custom modules (ADR-0004) |
| D5 | Compositor/desktop | Approved: **KWin + Plasma 6** (ADR-0005) |
| D6 | Licensing | Approved with change: code GPL-3.0-or-later, fonts OFL-1.1, artwork CC-BY-SA-4.0. Name + logo all rights reserved, see `TRADEMARKS.md` (ADR-0006) |
| D7 | Repo | Approved: private `zeewolf121-rgb/zeeos` |
| D8 | Codex access | Codex cloud via the GitHub integration. `@codex review` on Claude-authored PRs, `@codex` task comments on `model:codex` issues, `needs-human` fallback |
| D9 | aarch64 CI | Self-hosted macOS ARM64 runner for aarch64 builds and tests. Setup: `docs/ci/macos-arm64-runner.md`. Wiring is a Phase 1 issue |
| D10 | Release signing | **minisign**: offline root key, dedicated CI key in secrets (ADR-0007) |

## After approval

1. Merge the Phase 0 PR, then turn on branch protection for `main`.
2. Open Phase 1 issues (see `phase-1.md`) and dispatch them. Open the Phase 4 `installer-disk` issues from D3.
3. Project board: after the owner runs `gh auth refresh -h github.com -s project,read:project`, run `scripts/gh-bootstrap.sh`.
