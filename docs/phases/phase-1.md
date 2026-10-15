# Phase 1 plan: live ISO boots in QEMU on both architectures

**Exit criterion:** `boot-test.yml` is green for x86_64 and aarch64, with Secure Boot ON and OFF, and shows the live session reaching a login-free Plasma Wayland desktop. Evidence is a serial log marker plus a screenshot.

## Issues (concurrency cap: 2 Claude + 1 Codex, starts staggered 5 minutes, MISSION §11)

| ID | Title | Agent | Model | Arch | Deps |
|---|---|---|---|---|---|
| P1-1 | kiwi-ng skeleton: minimal Fedora live ISO (x86_64) | image-builder | claude | x86_64 | — `parallel-safe` |
| P1-2 | Build container + `make iso` wiring + package snapshot pinning | image-builder | claude | both | — `parallel-safe` |
| P1-3 | CI: `build-iso.yml` matrix, caching, artifact upload | ci-engineer | claude | both | — `parallel-safe` |
| P1-10 | Self-hosted macOS ARM64 runner: wiring, `runner-check` workflow, setup script (D9) | ci-engineer | claude | aarch64 | — `parallel-safe` |
| P1-4 | Secure Boot chain doc + verify shim/GRUB/kernel signatures in the built ISO | security-hardener | codex | both | — `parallel-safe` |
| P1-5 | Placeholder branding: logo (all rights reserved, `TRADEMARKS.md`), boot splash, wallpaper (original, CC-BY-SA) | theme-designer | codex | both | — `parallel-safe` |
| P1-6 | aarch64 overlay in `build/arch/aarch64` | image-builder | claude | aarch64 | P1-1 |
| P1-7 | QEMU harness: OVMF/AAVMF, SB on/off, serial marker, QMP screenshot | vm-integrator | claude | both | P1-1 |
| P1-8 | `boot-test.yml` using the harness | ci-engineer | claude | both | P1-3, P1-7 |
| P1-9 | Plasma Wayland autologin in the live session + desktop-ready marker unit | desktop-shell | claude | both | P1-1 |

## Lanes

```
Lane A:  P1-1 ─┬─► P1-6 ─┐
               ├─► P1-7 ─┼─► P1-8  ──► integration checkpoint
               └─► P1-9 ─┘     ▲
Lane C:  P1-2, P1-3, P1-10 ────┘
Lane D:  P1-4  (Codex)
Lane B:  P1-5  (Codex)
```

Waves (2 Claude + 1 Codex at a time):

1. P1-1 (image-builder) and P1-3 (ci-engineer), started 5 minutes apart. P1-4 (Codex).
2. P1-2 and P1-10 as Claude slots free up. P1-5 (Codex) after P1-4.
3. P1-6, P1-7, P1-9 once P1-1 has merged, then P1-8.

P1-1 and P1-2 both write `/build`, so they never run at the same time.
