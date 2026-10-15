# Conventions

## Git

- `main` is protected. Changes land only through PRs.
- Branch names: `agent/<agent>/<issue>-<slug>`, for example `agent/image-builder/12-kiwi-skeleton`. Humans use `human/<name>/<issue>-<slug>`.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/). The scope is the top-level directory: `feat(installer): add BitLocker preflight check`.
- One issue per PR. A PR description must include `Closes #N`.

## Scope rules

- Every agent writes only inside the directories it owns (see `docs/agents.md`). If a change needs another agent's directory, open a new issue for that agent and mark yours `blocked-by:#N`.
- `/docs/adr/` changes need a `decision` label and the owner's approval.

## Merge requirements

1. All required CI checks are green.
2. Approved by the **other** model: Codex reviews Claude PRs, a Claude agent reviews Codex PRs. Nobody approves their own PR.
3. The owner approves anything labeled `decision` or `installer-disk`.
4. The PR template is filled in, including **test evidence**: a link to the CI run, the boot log excerpt, and a screenshot when the change is visible.

## Disagreements

Each model writes its position in five bullets or fewer as a PR comment headed `Position (<model>)`, then labels the PR `needs-decision`. The owner decides. No back-and-forth rounds after that.

## Code style

| Language | Rule |
|---|---|
| Shell | `#!/usr/bin/env bash`, `set -euo pipefail`, must pass shellcheck |
| Python (Calamares modules, tests) | 3.12+, ruff + ruff format, type hints, pytest |
| QML / JS (Plasma) | Qt 6, `qmllint` clean |
| YAML | yamllint default + 120-character lines |
| Files | SPDX license header on every file, or a REUSE.toml entry (ADR-0006) |

## Disk safety (`installer-disk`)

Any code that can write to a block device, a partition table, an ESP or NVRAM:

- is labeled `installer-disk`,
- has a dry-run mode that the tests use,
- logs every planned operation before doing it,
- is covered by `install-test.yml`, which checks that pre-existing ESP files and NTFS data checksums didn't change.

## Evidence, not claims

Never mark an issue or a PR as done without linking the CI run that proves it. If a test was skipped, write that it was skipped and why.
