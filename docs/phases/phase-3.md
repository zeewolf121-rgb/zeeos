# Phase 3 plan: layout modes, design language, keymaps

> **Amended by ADR-0009 (owner decision, #203/#204):** Arabic is no longer a ZeeOS requirement. The RTL step, the `ZEEOS_RTL_OK` / `ZEEOS_RTL_FAIL` markers, `screenshot-rtl.ppm` and the explicit Arabic packages are out of this phase and its exit criterion. They are removed in ADR-0009's landing order: vm #206 and ci #209, then desktop #205, then build #207. Upstream locales and RTL support stay as Fedora and KDE ship them.

**Exit criterion:** on `main`, `boot-test.yml` is green on all four cells (x86_64/aarch64 × Secure Boot on/off). Each cell's serial log has everything Phase 2 requires, plus, in this order:
- `ZEEOS_LAYOUT_OK mode=windows …`
- `ZEEOS_LAYOUT_OK mode=mac …`
- `ZEEOS_LAYOUT_OK mode=hybrid …` (the default, applied last so the session ends where it started)

Each cell uploads one screenshot per step (light, dark, windows, mac, hybrid). The image diff against committed baselines **gates** the cell (P3-8), as Phase 2 promised.

`ZEEOS_LAYOUT_OK` is printed by a guest-side check, and only if the panels Plasma reports after `zee-layout set <mode>` match the mode's spec (table below), and the mode's keymap profile is active.

**Boot chain:** no impact on either architecture. Everything here is userland config, QML and KWin scripts under `desktop/live/overlay/` plus packages from the signed Fedora repos. No kernel, shim, GRUB or initrd change.

## Scope rules for this phase

- **Config, QML and KWin scripts, not a fork** (ADR-0005). No compiled code. If a goal can't be met without it, the agent stops and opens a `decision` issue.
- **Three look-and-feel packages** `org.zeeos.windows`, `org.zeeos.mac`, `org.zeeos.hybrid`, each with a layout script (`contents/layouts/org.kde.plasma.desktop-layout.js`). They reuse the Phase 2 components (colour schemes, wallpaper, fonts) through `org.zeeos.base`'s defaults and replace it as `LookAndFeelPackage` with `org.zeeos.hybrid`. Hybrid is the default (MISSION §5).
- **Everything desktop-shell adds lives under `desktop/live/overlay/`**, which `build-iso.sh` already copies (#68). No new image wiring.
- **Art belongs to theme-designer (`/branding`).** The traffic-light window decoration art (P3-9) is Codex work off the critical path: until it lands, the Mac and Hybrid layouts use Breeze with the button order changed.
- **Use what Fedora ships.** Any other applet, font or icon set needs a licence check (ADR-0006) and a `decision` issue. Package names are checked with `dnf repoquery` in the build container, not guessed.
- **Package pinning order** as in Phase 2: if `build/arch/*/packages.lock` exists on `main` when P3-1 merges, P3-1 carries refreshed locks (Orchestrator tasks).
- **Parallel desktop-shell work** (P3-2 and P3-4) writes disjoint directories; each adds its own section to `desktop/README.md`, so a conflict there is a rebase, not a redesign.

## Layout spec (what P3-2 builds and P3-6 checks)

| Mode | Panels | Keymap profile |
|---|---|---|
| windows | one bottom panel: Kickoff, centered Icons-only Task Manager, tray, clock | `win`: Meta opens Kickoff, Meta+arrows quick-tile, Alt+Tab |
| mac | top panel: Kickoff (app icon), Global Menu, tray, clock; bottom floating dock: Icons-only Task Manager | `mac`: Meta+Space KRunner (centered), Meta+Q close, Meta+Tab switcher; Ctrl/Meta swap off by default, offered as an option |
| hybrid | top panel: Global Menu, tray, clock; bottom floating panel: Kickoff, centered Icons-only Task Manager | `win` shortcuts plus Meta+Space KRunner |

Window buttons: windows = right (min, max, close); mac and hybrid = left (close, min, max). Every mode gets the snap-layout picker and tiling toggle (P3-4). The dock has no magnification until the owner decides the applet (Decisions needed).

## Issues (concurrency cap: 2 Claude + 1 Codex, starts staggered 5 minutes, MISSION §11)

| ID | Title | Agent | Model | Arch | Budget | Deps |
|---|---|---|---|---|---|---|
| P3-1 | Packages for Phase 3: `kde-gtk-config` (#118, if still open), the GTK3 global-menu module (the Arabic locale and font entries it once added are removed by #207, ADR-0009). Add only what `dnf repoquery` shows is missing | image-builder | claude | both | small 15 | — `parallel-safe` |
| P3-2 | Three look-and-feel packages (`org.zeeos.windows`, `org.zeeos.mac`, `org.zeeos.hybrid`) with layout scripts per the Layout spec; `org.zeeos.hybrid` becomes `LookAndFeelPackage` in `/etc/xdg/kdeglobals`; window button order per mode | desktop-shell | claude | both | medium 40 | — `parallel-safe` |
| P3-3 | `zee-layout` switcher: CLI (`zee-layout get`, `zee-layout set windows\|mac\|hybrid [--dry-run]`) wrapping `plasma-apply-lookandfeel --resetLayout` and applying the mode's keymap profile (`kglobalshortcutsrc`, `kxkbrc`); plus a System Settings entry that calls it (no compiled code; else a `decision` issue). Plasma's Global Theme page keeps listing the three packages | desktop-shell | claude | both | medium 40 | P3-2 |
| P3-4 | KWin scripts under `usr/share/kwin/scripts/`: hover snap-layout picker on the maximize button (Plasma 6 custom tile layouts), and a tiling toggle (Meta+T). Enabled by default in `/etc/xdg/kwinrc` | desktop-shell | claude | both | medium 40 | — `parallel-safe` |
| P3-5 | Design-language effects in `/etc/xdg`: KWin blur and translucency for panels and menus, rounded corners where Breeze/KWin support them, tuned animation curves and speed; KRunner centered | desktop-shell | claude | both | small 15 | P3-2 |
| P3-6 | `zeeos-layout-check` (guest): after `ZEEOS_DARK_READY`, switch back to light, then run each mode with `zee-layout set`, read back panels and keymap, print `ZEEOS_LAYOUT_OK` (marker protocol below; the former RTL step is removed by #205, ADR-0009) | desktop-shell | claude | both | medium 40 | P3-1, P3-3 |
| P3-7 | Harness: when the guest prints `ZEEOS_LAYOUT_CHECK`, require each `ZEEOS_LAYOUT_OK` and screenshot after each (`screenshot-<mode>.ppm`; the former RTL requirement is removed by #206/#209, ADR-0009); otherwise behave as today. Per-step result in junit | vm-integrator | claude | both | medium 40 | — `parallel-safe` (backward-compatible, see the marker protocol) |
| P3-8 | Gating image diff in the shared harness: reads per-arch baselines from `build/arch/<arch>/baselines/` (arch data stays under `build/arch/`, CLAUDE.md rule 4), masked clock/cursor regions, a fixed threshold; a cell fails only on a step that has a baseline. The harness code is arch-neutral and lives in `/tests` | vm-integrator | claude | both | medium 40 | P3-6, P3-7 |
| P3-11 | Commit the approved baselines to `build/arch/<arch>/baselines/` (REUSE entry), taken from the artifacts of a green `main` run after P3-6, P3-7 and P3-8, linked in the PR | image-builder | claude | both | small 15 | P3-8 |
| P3-9 | `zee` window decoration art (Aurorae SVG theme, light and dark): original traffic-light buttons for Mac/Hybrid and plain buttons for Windows, nothing traced from Apple or Microsoft art, REUSE entries | theme-designer | codex | both | medium 40 | — `parallel-safe` |
| P3-10 | Point the three layouts' window decoration at the P3-9 theme (installed the way `branding/wallpapers/` is) | desktop-shell | claude | both | small 15 | P3-2, P3-9 |

## Orchestrator tasks (interactive session, not opened by autopilot)

- **P3-W** `boot-test.yml`: upload `screenshot-*.ppm` (not a fixed list), put the per-step results in the step summary, and raise `timeout-minutes` (45 today) to cover four more steps of about 150 s each under TCG. After P3-7, and make the diff step gating with P3-8. Workflow edit, so it gets `needs-human` and the phase can't complete until it's closed (same as #90 in Phase 2).
- **Lock refresh for P3-1**, when `build/arch/*/packages.lock` exists on `main`: dispatch `pin-packages` with `branch=<P3-1 branch>`.
- **Milestone:** the owner creates `Phase 3: …` and attaches #125 to it.

## Decisions needed (owner)

- **Magnifying dock** (ADR-0005: upstream-maintained parabolic zoom applet, pinned). If no maintained applet is in the Fedora repos, choose: package one in a ZeeOS COPR (licence check, ADR-0006), write our own QML applet, or ship v1 without magnification. Until then the Mac dock is a plain Icons-only Task Manager. Not on the exit path.

## Marker protocol (fixed here so P3-6 and P3-7 can run in parallel)

All markers go to the serial console, one per line. They follow the Phase 2 markers:
```
ZEEOS_THEME_CHECK
ZEEOS_LAYOUT_CHECK
ZEEOS_DESKTOP_READY
…Phase 2 markers…
ZEEOS_DARK_READY …
ZEEOS_LAYOUT_OK mode=windows panels=<n> keymap=win
ZEEOS_LAYOUT_OK mode=mac panels=<n> keymap=mac
ZEEOS_LAYOUT_OK mode=hybrid panels=<n> keymap=win
```
- `ZEEOS_LAYOUT_CHECK` is printed by the announce unit **before** `ZEEOS_DESKTOP_READY`, like `ZEEOS_THEME_CHECK`. The harness requires the layout markers only after seeing it, so P3-7 can merge before P3-6.
- Before the first mode, the guest switches back to light and waits for the repaint, so layout screenshots are comparable with the light baseline.
- For each mode, the guest runs `zee-layout set <mode>`, then reads back the panels (count, edge and applets, via `org.kde.PlasmaShell` `evaluateScript`) and the keymap profile, then waits 5 s for the repaint. On a mismatch it prints `ZEEOS_LAYOUT_FAIL <mode>: <reason>` and stops; the cell fails.
- Timing as in Phase 2: there's no harness-to-guest channel, so the guest waits **150 s** after each marker before the next switch (`zeeos.layout_delay=<s>` on the kernel command line). That's longer than the harness's 90 s TCG settle delay (#84); if one changes, so must the other.
- The harness screenshots after each `ZEEOS_LAYOUT_OK` (`screenshot-windows.ppm`, `-mac`, `-hybrid`), with the settle delay. Any `ZEEOS_LAYOUT_FAIL` fails the cell. Until #205 lands, a guest that still prints `ZEEOS_RTL_FAIL` also fails it (ADR-0009 landing order).

## Lanes

```
Lane E:  P3-2 ─► P3-3 ─► P3-6 ─┐
                          ▲     │
Lane A:  P3-1 ────────────┘     ├─► P3-8 ─► integration checkpoint (exit test on main)
Lane A:  P3-7 ─► P3-W (orchestrator) ┘
Lane E:  P3-2 ─► P3-5;  P3-4           (not on the exit path)
Lane B:  P3-9 ─► P3-10 (also needs P3-2; not on the exit path)
```

P3-4, P3-5 and P3-10 aren't checked by markers. Their PRs link boot-test screenshots as evidence. If one merges after P3-8 and changes a screenshot, its PR opens an image-builder issue to re-approve the baselines (`build/arch/` isn't desktop-shell's scope).

## Carried over

- #118 kde-gtk-config (GTK3 dark sync) is folded into P3-1.
- #8, #55 build-container caching; #45 / #80, #82 package pinning (ADR-0008).
- First-run wizard (layout mode, theme, accent) stays in Phase 6 and will call `zee-layout`.
