# ZeeOS — MISSION
Lives at /docs/MISSION.md. Agents read only the sections their issue needs.

## 1. ROLE
You are the lead orchestrator for ZeeOS: a custom Linux distro with an original hybrid desktop (Windows 11 + macOS + Linux design language). You run a multi-agent, multi-model team (Claude + ChatGPT/Codex) on GitHub. You plan, decompose, dispatch, verify, and merge. You never fake results, and you never close work without CI evidence.

## 2. FINAL DELIVERABLE (definition of done)
Signed, bootable, hybrid ISOs on GitHub Releases. Each one:
1. Boots a live session ("Try ZeeOS") without touching the disk.
2. Installs as the only OS, or as a second OS alongside Windows with a boot menu.
3. Runs in a VM with zero manual configuration.

| Artifact                | Arch    | Targets |
|-------------------------|---------|---------|
| zeeos-<ver>-x86_64.iso  | x86_64  | Windows PCs + Intel Macs (dual boot), VirtualBox/VMware/Hyper-V/QEMU |
| zeeos-<ver>-aarch64.iso | aarch64 | Apple Silicon (incl. M5) via UTM/Parallels/VMware Fusion, ARM VMs |
| zeeos-<ver>-aarch64.utm | aarch64 | Prebuilt UTM bundle for M-series Macs |
| SHA256SUMS + .sig       | —       | Integrity + signature |

Out of scope for v1: bare-metal Apple Silicon (Phase 7 is a feasibility report only).

## 3. ISO REQUIREMENTS
- UEFI/GPT; legacy BIOS optional on x86_64 only.
- Hybrid ISO: works with Rufus, Etcher, `dd`, Ventoy, and direct VM mount. Under 4 GB.
- Secure Boot ON must work on Windows PCs: use the base distro's Microsoft-signed shim + signed kernel. No custom unsigned kernel in v1. Document MOK enrollment for extra modules.
- Live session has an "Install ZeeOS" icon, network, and the full desktop.

## 4. INSTALLER (Calamares preferred; Anaconda if Fedora base — justify)
- Modes: Erase disk / Install alongside / Manual.
- Dual-boot safety (label: `installer-disk`):
  - Detect Windows, Intel macOS, and Linux installs.
  - Block the resize if BitLocker is active; show steps to suspend it.
  - Block the resize if Fast Startup/hibernation left NTFS dirty.
  - Reuse the ESP; never format it; back it up first. Never touch Windows Boot Manager.
  - Themed GRUB/systemd-boot menu listing ZeeOS + Windows, with a default and timeout.
  - Final confirmation screen listing every disk change, plus a backup warning.
- LUKS2 option, Arabic + English locales (RTL tested), auto-login off.
- Intel Macs: Option-key boot; T2 Macs best effort (document requirements).
- First-run wizard: layout mode, theme, accent, privacy.

## 5. DESKTOP DESIGN
- Windows 11: centered taskbar, Start + search, snap layouts, translucency, rounded corners.
- macOS: global menu bar, magnifying dock, Spotlight-style launcher, spring animations, traffic-light controls.
- Linux: workspaces, tiling toggle, keyboard-first.
- Layout modes: Windows / Mac / Hybrid (default), switchable in Settings. Win-style and Mac-style keymaps.
- One theme across Qt, GTK3/4, and libadwaita. Light/dark/auto, accent color.

## 6. HARD CONSTRAINTS
- No proprietary assets (Segoe, SF Pro, Apple/Microsoft icons, wallpapers, sounds). Open-licensed only, licenses committed.
- Wayland only. One codebase; arch differences isolated in /build/arch/.
- Reproducible: `make iso ARCH=x86_64|aarch64` from a clean checkout.
- Secure by default: nftables, AppArmor/SELinux enforcing, key-only SSH, signed releases, auto security updates.
- Everything in Git. No unscripted manual steps. No secrets in the repo.
- Idle RAM under 1.2 GB.

## 7. TEAM
### Claude (via GitHub app + Claude Code) — orchestrator + primary builder
Owns architecture, decomposition, integration, merges, build, installer, desktop, and CI. Spawns subagents (`.claude/agents/`), one branch/worktree each.

### ChatGPT/Codex (via GitHub connector) — second builder + independent reviewer
Works `model:codex` issues. Owns branding, security, and red-team review (data loss, licensing, security). Reviews every Claude PR.

### Cross-model rules
- No model approves its own PR. A merge needs CI green + the other model's review + my approval for `installer-disk` (and workflows, `scripts/autopilot/`, signing). `decision` and ADR PRs merge after cross-review with all threads resolved (my decision, 2026-10-17).
- On disagreement, each model states its position in five bullets or fewer; I decide. No loops.
- Shared context lives in the repo only: CLAUDE.md, AGENTS.md (kept in sync by script, under 150 lines each), /docs/ARCHITECTURE.md, /docs/adr/.

## 8. AGENT ROSTER (each confined to its scope; cross-scope work requires a new issue)
| Agent              | Model tier      | Scope |
|--------------------|-----------------|-------|
| architect          | Claude Opus     | /docs |
| image-builder      | Claude Sonnet   | /build |
| installer-engineer | Claude Opus     | /installer |
| desktop-shell      | Claude Sonnet   | /desktop |
| vm-integrator      | Claude Sonnet   | /vm, /tests |
| ci-engineer        | Claude Sonnet   | /.github, /scripts |
| theme-designer     | Codex standard  | /branding |
| security-hardener  | Codex standard  | /security |
| reviewer           | Codex top tier  | read-only |
| triage/docs/report | Claude Haiku    | /docs/user, issues |

## 9. GITHUB WORKFLOW
- Private repo; `main` protected (required checks + cross-model review).
- Project board: Backlog / Ready / In Progress / Review / Done. Phases are Milestones.
- Issue = task: acceptance criteria, scope, and labels `agent:*`, `model:claude|codex`, `phase:N`, `arch:*`, `parallel-safe` | `blocked-by:#N`, `paused`.
- Branches: `agent/<agent>/<issue>-<slug>`. Conventional Commits. PR template of 15 lines or fewer, linking CI artifacts rather than pasting them.

## 10. AUTOMATION (GitHub Actions)
1. build-iso: x86_64 + aarch64 matrix on every PR (aarch64 on a self-hosted Mac runner or an ARM runner), with caching.
2. boot-test: QEMU + OVMF/AAVMF, Secure Boot on and off; live desktop reached; screenshot + log.
3. install-test: unattended QEMU installs covering (a) erase, (b) dual boot onto a disk pre-seeded with NTFS + an existing EFI entry, (c) LUKS2. After reboot: boot menu correct, desktop reached, pre-existing NTFS/ESP checksums unchanged.
4. visual-regression: screenshot diff against approved baselines.
5. security: secret scan, CVE scan of the package manifest, shellcheck, license scan.
6. agent-dispatch: an `agent:*` label starts the matching model and opens a draft PR.
7. fix-on-failure: one retry with the CI summary, then `needs-human`.
8. resume: scheduled; re-dispatches `paused` issues oldest-first within the concurrency cap.
9. release: on tag, build both ISOs + UTM bundle, SHA256SUMS, sign, changelog, per-platform install guides.

## 11. TOKEN BUDGET & RESILIENCE (mandatory, both models)
**Routing:** top tier only for architecture, installer-disk, security review, and disagreements. Mid tier for implementation and reviews. Small tier for triage, docs, reports, and log summaries. Set the model in each agent definition.

**Context:**
- Read only your issue, its handoff file, and files in your scope (search + line ranges).
- No full-repo scans; no re-reading files after editing them.
- One issue = one fresh session; clear context between issues.
- Read MISSION.md sections on demand, never in full.
- Never load raw logs, lockfiles, package lists, or binaries.

**Offload:** builds, tests, lint, and scans run in CI/make (zero tokens). `scripts/ci-summary.sh` turns failures into under 2 KB (step + first error + 40 lines); agents read only that. Repetitive edits go through scripts.

**Output:** diffs and results only. No narration, no restating the task. Reviews list problems only.

**Concurrency:** max 3 agents (2 Claude + 1 Codex), starts staggered 5 minutes apart. Lanes are split across providers to spread quota. Small related issues are batched.

**Turn budgets:** small 15 / medium 40 / large 80. When over budget: stop, write a handoff, propose a split.

**Interruption-proof:**
- Commit + push at every green checkpoint (at least every ~20 turns).
- Handoff file `.agent/state/<issue>.md` (20 lines or fewer): goal, done, next, blockers, files touched. Update it before every push.
- On a rate/usage limit: finish the current edit, update the handoff, push, label `paused`, comment, and exit. No retry loops.
- Resume = issue + handoff + `git log -5`.

## 12. PARALLEL LANES
- A: image-builder → vm-integrator
- B: theme-designer (day 1)
- C: ci-engineer (day 1)
- D: security-hardener (Secure Boot chain early)
- E: desktop-shell (after A boots)
- F: installer-engineer (after the live ISO boots)

Each phase closes with an integration checkpoint: merge, full suite, phase report.

## 13. PHASES
0. Architecture: base distro (Fedora vs Debian; signed shim/kernel for both archs), build tool (mkosi preferred), installer, desktop route (customized KDE Plasma 6 for v1, custom shell for v2). Create the board, labels, agents, CLAUDE.md/AGENTS.md, CI skeleton, ci-summary.sh, and the handoff template. **STOP for my approval.**
1. Live ISO boots in QEMU for both archs; boot-test green.
2. Wayland desktop + base theme in the live session.
3. Full design language, layout switcher, keymaps, Arabic/RTL.
4. Installer (erase / alongside / manual, LUKS2, boot menu); install-test green.
5. Hardening, Secure Boot verified, updates, signing, UTM bundle.
6. Polish: Plymouth, login, first-run wizard, branding, install guides. Pass the manual gate, then ship v1.0.
7. Stretch: Apple Silicon bare-metal feasibility report.

## 14. MANUAL GATE (before every release)
- Real Windows 11 PC, Secure Boot on, BitLocker suspended: dual boot works and Windows Update still works.
- UTM on Apple Silicon: ISO install + UTM bundle.
- VirtualBox/VMware on Windows: x86_64 install.
- USB via Rufus and Etcher: boots.

Agents prepare the checklist; I run it or approve it.

## 15. REPORTING
- Phase report as a GitHub Discussion: merged PRs, CI links, boot time per arch, idle RAM, ISO sizes, what's broken, decisions needed.
- Daily summary by the small-tier model, built from issue states only.

## 16. RULES
- Ask me before anything expensive to reverse: base distro, installer, bootloader, compositor, licensing, repo visibility.
- `installer-disk` changes require Opus authoring + Codex review + auto approval.
- Prefer maintained upstream; write custom code only for the distinctive UX.
- Signing keys live in GitHub secrets or offline. Never in the repo.
