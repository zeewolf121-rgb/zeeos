# ZeeOS: shared agent context

ZeeOS is a Fedora 44-based (ADR-0001) Linux distro with an original hybrid desktop on KDE Plasma 6 / KWin (Wayland only). It ships signed hybrid ISOs for x86_64 and aarch64 and a UTM bundle. The installer is Calamares with custom dual-boot safety modules.

## Read first

- `docs/ARCHITECTURE.md`: components, boot chain, layout
- `docs/adr/`: decisions. Don't go against an Accepted ADR. Propose a new ADR instead.
- `docs/CONVENTIONS.md`: branches, commits, merge rules, disk-safety rules
- `docs/agents.md`: who owns which directory
- `docs/phases/`: the current phase plan

## Hard rules

1. **Stay in scope.** Write only inside directories your agent owns. Anything else needs a new issue. One exception for every agent: your own handoff file, `.agent/state/<issue>.md` (template: `.agent/state/TEMPLATE.md`).
2. **No proprietary assets.** No Segoe, SF Pro, Apple/Microsoft icons, wallpapers or sounds. Every asset needs a license entry (REUSE).
3. **Wayland only.** No X11 sessions or X11-only components.
4. **Arch differences live only in `build/arch/<arch>/`.**
5. **Reproducible.** Everything is scripted and `make iso ARCH=…` works from a clean checkout. No manual steps.
6. **No secrets in the repo.** Signing keys live in GitHub encrypted secrets or offline.
7. **Disk writes are dangerous.** Code that can write to disks, partition tables, an ESP or NVRAM must be labeled `installer-disk`, have a dry-run mode, never format an existing ESP, and never remove or overwrite Windows Boot Manager.
8. **Never fake results.** Don't mark work done without a linked CI run. Report skipped tests as skipped.
9. **No self-approval.** Codex orchestrates bounded Gemini/Claude tasks. An independent model reviews the exact head; existing required GitHub approvals/checks still apply. See `docs/AUTONOMY.md`. No agent approves its own code.
10. **Disagreements:** five bullets or fewer per model, then the owner decides.

## Commands

```bash
make iso ARCH=x86_64      # build the ISO (in the build container)
make boot-test ARCH=x86_64 SECUREBOOT=on
make lint                 # shellcheck, yamllint, reuse
scripts/sync-agent-docs.sh  # regenerate CLAUDE.md and AGENTS.md
```

## Branches and commits

Branch `agent/<agent>/<issue>-<slug>`. Use Conventional Commits with the top-level directory as the scope. Fill in the PR template, including test evidence.
