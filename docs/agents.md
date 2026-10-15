# Agent roster

| Agent | Model | Owns (write scope) | Lane |
|---|---|---|---|
| architect | Claude | `/docs` (not `/docs/user`) | — |
| image-builder | Claude | `/build`, `Makefile` | A |
| installer-engineer | Claude | `/installer` | F (after the live ISO boots) |
| desktop-shell | Claude | `/desktop` | E (after Lane A boots) |
| theme-designer | Codex | `/branding`, `/LICENSES` (asset licenses) | B (day one) |
| security-hardener | Codex | `/security` | D (Secure Boot chain early) |
| vm-integrator | Claude | `/vm`, `/tests` | A |
| ci-engineer | Claude | `/.github`, `/scripts` | C (day one) |
| reviewer | Codex | read-only: PR review, data-loss audit, license audit | — |
| docs-writer | either | `/docs/user`, `CHANGELOG.md` | — |

The orchestrator (Claude Code, top level) owns integration, merges, `CLAUDE.md`, `AGENTS.md` and `docs/agent-context.md`.

## Labels on every issue

`agent:<name>`, `model:claude|codex`, `phase:N`, `arch:x86_64|aarch64|both`, and either `parallel-safe` or `blocked-by:#N`. Add `installer-disk` and/or `decision` when they apply.

## Dispatch

`agent-dispatch.yml` reads the `model:` label:

- `model:claude` runs `anthropics/claude-code-action` with the subagent from `.claude/agents/<agent>.md`.
- `model:codex`: issue dispatch to Codex is not wired yet (D8 covers reviews only).

When a Claude-authored PR (`agent/<agent>/…` with a Claude agent, or `agent/orchestrator/…`) is opened or marked ready for review, `agent-dispatch.yml` comments `@codex review`. Codex cloud picks this up through its GitHub integration (D8).

Each run works on `agent/<agent>/<issue>-<slug>` and opens a **draft** PR.
