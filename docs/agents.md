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
| docs-writer | Gemini or Claude (bounded lane), either model interactively | `/docs/user`, `CHANGELOG.md` | — |

Every agent may also write its own handoff file, `.agent/state/<issue>.md`, for the issue it works on (template: `.agent/state/TEMPLATE.md`; autopilot's fix runs update it). Nothing else under `.agent/` is in any agent's scope.

Codex is the top-level orchestrator and owns integration, policy decisions, `CLAUDE.md`, `AGENTS.md` and `docs/agent-context.md`. Gemini and Claude implement/review bounded task-specific work. `docs/AUTONOMY.md` defines the opt-in local controller; until owner rollout, existing Actions workers retain their documented limits. Model output never grants permissions or approval.

## Labels on every issue

`agent:<name>`, `model:claude|codex|gemini`, `phase:N`, `arch:x86_64|aarch64|both`, and either `parallel-safe` or `blocked-by:#N`. Add `installer-disk` and/or `decision` when they apply.

## Dispatch

In legacy mode, `agent-dispatch.yml` reads the `model:` label:

- `model:claude` runs `anthropics/claude-code-action` with the subagent from `.claude/agents/<agent>.md`.
- `model:codex` runs `scripts/codex-dispatch.sh`: it comments `@codex` on the issue (as the owner, via `CODEX_TRIGGER_TOKEN`) with the task summary and a pointer to `AGENTS.md`. If Codex doesn't react or reply with a task link within 5 minutes, the issue gets `needs-human` and the owner starts it from Codex cloud.

When a Claude-authored PR (`agent/<agent>/…` with a Claude agent, or `agent/orchestrator/…`) is opened or marked ready for review, `agent-dispatch.yml` comments `@codex review`. Codex cloud picks this up through its GitHub integration (D8).

Each run works on `agent/<agent>/<issue>-<slug>` and opens a PR.

Autopilot (`docs/AUTOPILOT.md`) labels issues `ready` and dispatches them within the caps of 3 Claude + 1 Codex. It also runs cross-model reviews, CI retries and merges.

In `AUTOPILOT_CONTROLLER=codex-local` mode, legacy implementation, fix, resume and planning dispatch is held. Only explicitly labelled `autonomy:low-risk` documentation issues enter the bounded controller, which requires legacy workers/cloud tasks to drain. Gemini PRs receive independent Claude exact-head review; Claude PRs retain independent Codex review. No sensitive task is automatically downgraded into this lane.
