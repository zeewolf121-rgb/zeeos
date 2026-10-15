# Phase 1 plan: live ISO boots in QEMU on both architectures

**Exit criterion:** `boot-test.yml` is green for x86_64 and aarch64, with Secure Boot ON and OFF, and shows the live session reaching a login-free Plasma Wayland desktop. Evidence is a serial log marker plus a screenshot.

## Issues (concurrency cap: 4 agents)

| ID | Title | Agent | Model | Arch | Deps |
|---|---|---|---|---|---|
| P1-1 | kiwi-ng skeleton: minimal Fedora live ISO (x86_64) | image-builder | claude | x86_64 | — `parallel-safe` |
| P1-2 | Build container + `make iso` wiring + package snapshot pinning | image-builder | claude | both | — `parallel-safe` |
| P1-3 | CI: `build-iso.yml` matrix, caching, artifact upload | ci-engineer | claude | both | — `parallel-safe` |
| P1-4 | Secure Boot chain doc + verify shim/GRUB/kernel signatures in the built ISO | security-hardener | codex | both | — `parallel-safe` |
| P1-5 | Placeholder branding: logo, boot splash, wallpaper (original, CC-BY-SA) | theme-designer | codex | both | — `parallel-safe` |
| P1-6 | aarch64 overlay in `build/arch/aarch64` | image-builder | claude | aarch64 | P1-1 |
| P1-7 | QEMU harness: OVMF/AAVMF, SB on/off, serial marker, QMP screenshot | vm-integrator | claude | both | P1-1 |
| P1-8 | `boot-test.yml` using the harness | ci-engineer | claude | both | P1-3, P1-7 |
| P1-9 | Plasma Wayland autologin in the live session + desktop-ready marker unit | desktop-shell | claude | both | P1-1 |

## Lanes

```
Lane A:  P1-1 ─┬─► P1-6 ─┐
               ├─► P1-7 ─┼─► P1-8  ──► integration checkpoint
               └─► P1-9 ─┘     ▲
Lane C:  P1-2, P1-3 ───────────┘
Lane D:  P1-4  (Codex)
Lane B:  P1-5  (Codex)
```

First wave: P1-1, P1-2, P1-3 (Claude) together with P1-4 and P1-5 (Codex). That is four Claude-side agents at most, and Codex lanes are counted separately.
