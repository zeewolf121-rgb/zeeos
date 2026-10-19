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
- `etc/xdg/xdg-desktop-portal/plasma-portals.conf`: KDE portal first, so libadwaita gets colour-scheme and accent
  from `kdeglobals` (`ColorScheme`, `AccentColor`). Switching Plasma to ZeeOS Dark flips libadwaita (GTK4) apps;
  GTK3 apps stay light until kde-gtk-config is in the image (#118).
- Not verified in a guest yet; `zeeos-theme-check` (P2-4, below) covers it.

## Theme check (issue #96, P2-4)

- `usr/libexec/zeeos-theme-check` with `zeeos-theme-check-announce.service` (prints `ZEEOS_THEME_CHECK` before
  `ZEEOS_DESKTOP_READY`) and `zeeos-theme-check.service` (after desktop-ready: `ZEEOS_MEM`, light check,
  `ZEEOS_THEME_OK`, wait `zeeos.dark_delay` s (default 150), switch to dark, read back Plasma scheme, GTK theme and
  portal `color-scheme`, `ZEEOS_DARK_READY`; else `ZEEOS_THEME_FAIL <reason>`). Format: docs/phases/phase-2.md.
- Both units are pulled in by `Wants=` in `zeeos-desktop-ready.service`, so `build/` needs no change.
- Dark GTK3 is set by the script (`adw-gtk3-dark` in the user's `settings.ini`) until kde-gtk-config lands (#118).
- `DRY_RUN=1` prints without touching the serial tty. Not run in a guest yet; the boot-test CI run is the evidence.

Needs from image-builder: packages (`plasma-desktop`, `sddm`, `kwin`), a `liveuser` account, `graphical.target` as default,
`systemctl enable sddm zeeos-desktop-ready`, and this overlay installed. Not yet wired, so no boot evidence exists yet.
