# /desktop

Owner: `desktop-shell` (see docs/agents.md). Other agents: open an issue instead of editing here.

## live/overlay (issue #14)

Root-tree overlay for the live session, to be copied into the image by `build/` (image-builder):

- `etc/sddm.conf.d/10-zeeos-live-autologin.conf`: SDDM autologin of `liveuser` into `plasma.desktop`, Wayland only.
- `usr/lib/systemd/system/zeeos-desktop-ready.service` and `usr/libexec/zeeos-desktop-ready`: after login, print
  `ZEEOS_DESKTOP_READY` (the `vm/boot-test.sh` default marker) to the serial console once `plasmashell` runs
  with a Wayland socket and no Xorg. It is a root system unit, not a user unit, because a user cannot open the serial tty.
  `DRY_RUN=1` prints without writing to the tty.

## Base theme (issue #93, P2-2)

- `usr/share/color-schemes/ZeeOS{Light,Dark}.colors`: placeholder palette; the live session starts light.
- `etc/xdg/kdeglobals`, `etc/xdg/kcminputrc`: default scheme and accent, Breeze icons/cursor/style, Noto Sans fonts.
- `etc/sddm.conf.d/20-zeeos-theme.conf`: stock Breeze SDDM theme, Breeze cursor, Noto Sans.
- Wallpaper: the art lives in `branding/wallpapers/` (theme-designer). `usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/zeeos-wallpaper.js`
  sets the `ZeeOS` package once per user on first login (light/dark follows the colour scheme), and
  `etc/xdg/kscreenlockerrc` uses it on the lock screen. (Replaces the old `scripts/gen-wallpaper.sh` placeholder.)
- `usr/share/plasma/look-and-feel/org.zeeos.base`: minimal look-and-feel; `contents/defaults` sets the default
  wallpaper (`[Wallpaper]`, the `ZeeOS` package from `branding/wallpapers/`) and scheme. Selected through
  `LookAndFeelPackage` in `etc/xdg/kdeglobals`.

## GTK consistency (issue #95, P2-3)

- `etc/gtk-3.0/settings.ini`, `etc/gtk-4.0/settings.ini`: `adw-gtk3` theme (GTK3), Breeze icons/cursor, Noto Sans.
- `etc/skel/.config/gtk-3.0/settings.ini`: names `adw-gtk3` per user, because kde-gtk-config's first-login update
  writes `Breeze` into `~/.config/gtk-3.0/settings.ini` when that file names no theme (#143).
- `etc/xdg/xdg-desktop-portal/plasma-portals.conf`: KDE portal first, so libadwaita gets colour-scheme and accent
  from `kdeglobals` (`ColorScheme`, `AccentColor`). Switching Plasma to ZeeOS Dark flips libadwaita (GTK4) apps;
  GTK3 apps stay light until kde-gtk-config is in the image (#118).
- Not verified in a guest yet; `zeeos-theme-check` (P2-4, below) covers it.

## Theme check (issue #96, P2-4)

- `usr/libexec/zeeos-theme-check` with `zeeos-theme-check-announce.service` (prints `ZEEOS_THEME_CHECK` before
  `ZEEOS_DESKTOP_READY`) and `zeeos-theme-check.service` (after desktop-ready: `ZEEOS_MEM`, light check,
  `ZEEOS_THEME_OK`, wait `zeeos.dark_delay` s (default 150), switch to dark, read back Plasma scheme, GTK theme and
  portal `color-scheme` (after restarting plasmashell and waiting for it to answer on D-Bus, #170), `ZEEOS_DARK_READY`; else `ZEEOS_THEME_FAIL <reason>`). Format: docs/phases/phase-2.md.
- Both units are pulled in by `Wants=` in `zeeos-desktop-ready.service`, so `build/` needs no change.
- Dark GTK3 is set by the script (`adw-gtk3-dark` in the user's `settings.ini`) until kde-gtk-config lands (#118).
- `DRY_RUN=1` prints without touching the serial tty. Not run in a guest yet; the boot-test CI run is the evidence.

## Layout check (issue #134, P3-6)

- `usr/libexec/zeeos-layout-check` with `zeeos-layout-check-announce.service` (prints `ZEEOS_LAYOUT_CHECK` before
  `ZEEOS_DESKTOP_READY`) and `zeeos-layout-check.service` (after `zeeos-theme-check.service`, which it requires, so
  it only runs once `ZEEOS_DARK_READY` was printed). It switches back to light, then per mode runs `zee-layout set`,
  reads back the panels (edge and applets, via `org.kde.PlasmaShell` `evaluateScript`) and the keymap, and prints
  `ZEEOS_LAYOUT_OK mode=<m> panels=<n> keymap=<k>`, then waits `zeeos.layout_delay` s (default 150). The session
  stays in English and ends on hybrid. Failures print `ZEEOS_LAYOUT_FAIL <mode>: <reason>`.
- The expected panel strings in the script mirror the three `org.kde.plasma.desktop-layout.js` files: change both together.
- `DRY_RUN=1` prints without touching the serial tty. Not run in a guest yet; the boot-test CI run is the evidence.

## Layout packages (issue #128, P3-2)

- `usr/share/plasma/look-and-feel/org.zeeos.{windows,mac,hybrid}`: Look-and-Feel packages. Each has
  `contents/defaults` (same scheme and wallpaper as `org.zeeos.base`, plus `[kwinrc][org.kde.kdecoration2]` button
  order) and `contents/layouts/org.kde.plasma.desktop-layout.js` (panels, per docs/phases/phase-3.md "Layout spec").
- windows: one bottom panel (Kickoff, centered Icons-only Task Manager, tray, clock); buttons right (min, max, close).
- mac: top panel (Kickoff, Global Menu, tray, clock) plus a floating bottom dock (Icons-only Task Manager, no
  magnification yet); buttons left (close, min, max).
- hybrid (default): top panel (Global Menu, tray, clock) plus a floating bottom panel (Kickoff, centered Icons-only
  Task Manager); buttons left. `etc/xdg/kdeglobals` sets `LookAndFeelPackage=org.zeeos.hybrid`.
- `org.zeeos.light` and `org.zeeos.dark`: colour-scheme-only global themes (no layout or wallpaper).
  `etc/xdg/kdeglobals` sets `DefaultLightLookAndFeel` and `DefaultDarkLookAndFeel` to them so Quick Settings Theme
  offers ZeeOSLight and ZeeOSDark (#188). Not yet verified on a booted guest.
- `org.zeeos.base` stays as the defaults reference. Keymaps and switching belong to `zee-layout` (P3-3).
- Not verified in a guest yet: the layout scripts are untested until the boot-test CI run shows the hybrid panels.

## Design-language effects (issue #133, P3-5)

- `etc/xdg/kwinrc`: blur effect on (strength 8, noise 4), plus fade, squash and sliding-popup animations.
- `etc/xdg/kdeglobals`: `AnimationDurationFactor=0.75` (animations 25% faster).
- `etc/xdg/krunnerrc`: `FreeFloating=true` centers KRunner.
- Rounded corners and panel/menu translucency come from the Breeze style and Plasma theme defaults; blur applies to
  them. No per-panel opacity is forced in the layout scripts.
- Untested in a guest: boot-test screenshots from CI are the evidence, and none exists yet. The key names follow
  KWin/Plasma 6 and need confirming against the screenshots.

## Snap layouts and tiling toggle (issue #129, P3-4)

- `usr/share/kwin/scripts/zeeos-snap-layouts`: QML picker (Meta+Z) with five zone layouts; clicking a zone snaps the
  active window into it. `usr/share/kwin/scripts/zeeos-tiling`: Meta+T toggles master-stack auto-tiling, off restores geometry.
- `etc/xdg/kwinrc` enables both scripts by default.
- Deviation from the issue: a KWin script cannot hook the decoration's maximize button, so the picker opens from a
  shortcut, not on hover. A hover trigger needs the decoration theme (P3-9/P3-10) or a KWin change; follow-up issue needed.
- Not the Plasma 6 custom-tile API (those layouts are per-user in `kwinrc`, not shippable as defaults), so zones are
  fractions of the work area.
- Meta+T is also Plasma's built-in "Toggle Tiles Editor"; the conflict must be resolved in the keymap profiles (P3-3).
- Untested in a guest: the boot-test CI run and screenshots are the evidence, and none exists yet.

## Layout switcher (issue #132, P3-3)

- `usr/bin/zee-layout`: `get [mode|keymap]`, `set windows|mac|hybrid [--dry-run] [--swap-ctrl-meta]`. `set` runs
  `plasma-apply-lookandfeel --apply org.zeeos.<mode> --resetLayout`, then writes the keymap profile
  (`kglobalshortcutsrc` via `kwriteconfig6`, `kxkbrc` Options) and the state (`~/.config/zeeosrc` `[Layout]`).
  `--dry-run` prints every command and writes nothing. Ctrl/Meta swap is mac-only and off unless asked.
- Profiles: `win` (windows, hybrid; hybrid adds Meta+Space KRunner) and `mac`, per docs/phases/phase-3.md "Layout spec".
  Meta+T stays the ZeeOS tiling toggle in every profile: Plasma's "Edit Tiles" moves to Meta+Shift+T.
- `usr/share/applications/zeeos-layout.desktop`: "Layout Mode" in the Settings category with one action per mode.
  Deviation: a real page inside System Settings is a KCM (compiled code), so this is a launcher entry in the Settings
  menu and KRunner, not a sidebar page. The Global Theme page still lists the three packages. Owner decision needed
  if a sidebar page is required (`decision` issue).
- The shortcut action names (`Window Quick Tile Left`, `Edit Tiles`, `activate application launcher`, KRunner `_launch`)
  are from Plasma 6 as remembered, not checked against 6.7 in a guest. Untested in a guest; the boot-test run
  and `zeeos-layout-check` (P3-6) are the evidence.

Needs from image-builder: packages (`plasma-desktop`, `sddm`, `kwin`), a `liveuser` account, `graphical.target` as default,
`systemctl enable sddm zeeos-desktop-ready`, and this overlay installed. Not yet wired, so no boot evidence exists yet.
