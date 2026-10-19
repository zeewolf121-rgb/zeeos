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
- `scripts/gen-wallpaper.sh <root> [light|dark]`: generates the placeholder gradient wallpaper (no committed art).
  Needs from image-builder: run it against the image root at build time. Pointing Plasma at it is left to a follow-up.

## GTK consistency (issue #95, P2-3)

- `etc/gtk-3.0/settings.ini`, `etc/gtk-4.0/settings.ini`: `adw-gtk3` theme (GTK3), Breeze icons/cursor, Noto Sans.
- `etc/xdg/xdg-desktop-portal/plasma-portals.conf`: KDE portal first, so libadwaita gets colour-scheme and accent
  from `kdeglobals` (`ColorScheme`, `AccentColor`). Switching Plasma to ZeeOS Dark flips libadwaita (GTK4) apps;
  GTK3 apps stay light until kde-gtk-config is in the image (#118).
- Not verified in a guest yet; `zeeos-theme-check` (P2-4) will cover it.

Needs from image-builder: packages (`plasma-desktop`, `sddm`, `kwin`), a `liveuser` account, `graphical.target` as default,
`systemctl enable sddm zeeos-desktop-ready`, and this overlay installed. Not yet wired, so no boot evidence exists yet.
