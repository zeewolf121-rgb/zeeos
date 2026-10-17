# Phase 2 plan: Wayland desktop + base theme in the live session

**Exit criterion:** on `main`, `boot-test.yml` is green on all four cells (x86_64/aarch64 × Secure Boot on/off). Each cell's serial log has:
- `ZEEOS_DESKTOP_READY`
- `ZEEOS_THEME_OK`
- `ZEEOS_DARK_READY`
- a `ZEEOS_MEM` idle-RAM line

Each cell uploads a **light and a dark screenshot** showing the ZeeOS colour scheme and wallpaper, with no Fedora logo.

`ZEEOS_THEME_OK` is printed by a guest-side check, and only if all of these hold:
- the effective Qt colour scheme is ZeeOS's
- the GTK3 theme and the portal `color-scheme` agree with it
- GTK4/libadwaita follows the portal colour scheme and accent (libadwaita loads no third-party themes, ADR-0005)
- `fedora-logos` is not installed

Visual pixel-diff baselines are **report-only** in this phase. They become gating in Phase 3, once the design language settles.

## Scope rules for this phase

- **Theme, not layout.** Ship reusable components (colour schemes, GTK settings, cursor/font config, wallpaper) applied through `/etc/xdg` defaults. Keep Plasma's default panel. Phase 3 adds the three look-and-feel packages (Windows / Mac / Hybrid, ADR-0005) that reference these components.
- **Use what Fedora KDE ships** (Breeze icons and cursor, Noto fonts, which also cover Arabic for Phase 3 RTL). Any other font or icon set needs a licence check (ADR-0006) and a `decision` issue.
- **Codex art is off the critical path.** desktop-shell ships neutral placeholder art (a generated gradient wallpaper, REUSE-licensed). theme-designer's final art (#10, moved to Phase 6) replaces it in one file.
- **Package pinning order.** If #80 (ADR-0008) lands mid-phase, every package addition here needs refreshed locks (through #82). Either land the P2-1 package changes before #80, or include the lock refresh in the PR.

## Issues (concurrency cap: 2 Claude + 1 Codex, starts staggered 5 minutes, MISSION §11)

| ID | Title | Agent | Model | Arch | Deps |
|---|---|---|---|---|---|
| P2-1 | Remove Fedora branding from the image (`fedora-logos` → `generic-logos`, no `01-breeze-fedora` SDDM theme). Add theme packages (`adw-gtk3-theme`, portals). Copy `desktop/theme/` into the image | image-builder | claude | both | — `parallel-safe` |
| P2-2 | Base theme components: ZeeOS Light/Dark colour schemes, default accent, Breeze cursor and icons, Noto fonts, placeholder wallpaper, `/etc/xdg` defaults, SDDM Breeze with ZeeOS colours | desktop-shell | claude | both | — `parallel-safe` |
| P2-3 | GTK3/GTK4/libadwaita consistency: GTK settings defaults, adw-gtk3 for GTK3, portal colour-scheme and accent for libadwaita | desktop-shell | claude | both | P2-2 |
| P2-4 | `zeeos-theme-check` (guest): verify the effective theme and print `ZEEOS_THEME_OK`, switch to dark and print `ZEEOS_DARK_READY`, print `ZEEOS_MEM` at desktop-ready | desktop-shell | claude | both | P2-2, P2-3 |
| P2-5 | Harness: wait for the theme and dark markers, take light and dark screenshots, record idle RAM and boot time in junit properties; report-only image diff | vm-integrator | claude | both | — `parallel-safe` (marker protocol fixed in this plan) |
| P2-6 | `boot-test.yml`: upload both screenshots, put boot time and idle RAM in the step summary | ci-engineer | claude | both | P2-5 |

## Carried over from Phase 1

- #8, #55: build-container caching (ci-engineer, image-builder).
- #45 / #80, #82: package pinning (ADR-0008).
- Moved out: #9 and #15 → Phase 5, #10 → Phase 6. None was part of Phase 1's exit test.

## Marker protocol (fixed here so P2-4 and P2-5 can run in parallel)

All markers go to the serial console, one per line, in this order:
```
ZEEOS_DESKTOP_READY
ZEEOS_MEM total_kb=<n> available_kb=<n> used_kb=<n>
ZEEOS_THEME_OK scheme=<name> gtk=<name> portal=<prefer-light|prefer-dark>
ZEEOS_DARK_READY
```
- On a failed check, print `ZEEOS_THEME_FAIL <reason>` instead of `ZEEOS_THEME_OK`, and skip the dark switch.
- The harness screenshots after `ZEEOS_THEME_OK` (light) and after `ZEEOS_DARK_READY` (dark), each with the TCG settle delay (#84).

## Lanes

```
Lane E:  P2-2 ─► P2-3 ─► P2-4 ─┐
Lane A:  P2-1 ──────────────────┼─► integration checkpoint (exit test on main)
Lane A:  P2-5 ─► P2-6 (Lane C) ─┘
```

## Owner actions (not gates)

- Start #9 and #10 in Codex cloud (Codex didn't pick them up in Phase 1).
- #15: self-hosted macOS ARM64 runner, so aarch64 boots use HVF instead of TCG.
