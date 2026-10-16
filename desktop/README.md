# /desktop

Owner: `desktop-shell` (see docs/agents.md). Other agents: open an issue instead of editing here.

## live/overlay (issue #14)

Root-tree overlay for the live session, to be copied into the image by `build/` (image-builder):

- `etc/sddm.conf.d/10-zeeos-live-autologin.conf`: SDDM autologin of `liveuser` into `plasma.desktop`, Wayland only.
- `usr/lib/systemd/system/zeeos-desktop-ready.service` and `usr/libexec/zeeos-desktop-ready`: after login, print
  `ZEEOS_DESKTOP_READY` (the `vm/boot-test.sh` default marker) to the serial console once `plasmashell` runs
  with a Wayland socket and no Xorg. It is a root system unit, not a user unit, because a user cannot open the serial tty.
  `DRY_RUN=1` prints without writing to the tty.

Needs from image-builder: packages (`plasma-desktop`, `sddm`, `kwin`), a `liveuser` account, `graphical.target` as default,
`systemctl enable sddm zeeos-desktop-ready`, and this overlay installed. Not yet wired, so no boot evidence exists yet.
