# ADR-0005: Desktop and compositor

- Status: **Proposed** (needs owner approval)
- Date: 2026-10-16

## Decision (proposed)

- **v1: customized KDE Plasma 6 on KWin (Wayland only).** No X11 session is installed.
- **v2: custom shell.** Decide in v1.x whether that means a new Plasma shell package (QML on top of KWin) or a separate compositor. Not in scope now.

## How each design goal maps onto Plasma 6

| Goal | Plasma 6 mechanism | Custom work |
|---|---|---|
| Centered taskbar, Start menu + search | Panel + centered Icons-only Task Manager, Kickoff/KRunner | Layout template, Start menu styling |
| Snap layouts | KWin quick tiling + custom tile layouts (Plasma 6) | KWin script for a hover "snap layout" picker on the maximize button |
| Translucency, rounded corners, blur | KWin blur effect, Breeze-based window decoration | `zee` window decoration + Kvantum-free QtQuick style |
| Global menu bar | Global Menu applet + top panel | Layout template |
| Dock with magnification | Bottom panel with a parabolic zoom task manager (upstream-maintained applet, pinned) | Package and theme it; write our own only if no maintained applet exists |
| Spotlight-style launcher | KRunner, centered | Theme + shortcut (Meta+Space) |
| Spring animations | KWin effects, animation curves | Tuned effect settings |
| Traffic-light controls | Window decoration button order + theme | Decoration theme (original art, not Apple's) |
| Workspaces, tiling toggle, keyboard-first | Virtual desktops, KWin tiling, global shortcuts | Shortcut profile + tiling toggle script |
| Layout modes Windows / Mac / Hybrid | Plasma Look-and-Feel packages + layout JS (`plasma-apply-lookandfeel`) | `zee-layout` switcher (Settings page + CLI), three LnF packages |

## Consequences

- We ship config, QML and KWin scripts, not a fork. Plasma updates arrive through the base distro.
- Visual regression baselines have to be re-approved when Plasma changes how things look upstream.
