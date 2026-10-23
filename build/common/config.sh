#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# kiwi-ng image config script: runs inside the image root at the end of the prepare step.
set -euxo pipefail

echo "ZeeOS" >/etc/hostname
systemctl set-default graphical.target
systemctl enable NetworkManager.service sddm.service zeeos-desktop-ready.service

# Live desktop user (autologin comes from the desktop/live overlay's SDDM config); passwordless.
useradd -m -G wheel -s /bin/bash liveuser
passwd -d liveuser

# The live session never locks, dims or blanks: Plasma's defaults lock after 5 idle minutes and
# turn the display off later, which put the lock screen and a black screen into the boot-test
# layout screenshots (run 39859797537). Only liveuser gets this; installed users keep the defaults.
install -d -o liveuser -g liveuser -m 0755 /home/liveuser/.config
printf '[Daemon]\nAutolock=false\nLockOnResume=false\n' >/home/liveuser/.config/kscreenlockerrc
for profile in AC Battery LowBattery; do
  printf '[%s][Display]\nDimDisplayWhenIdle=false\nTurnOffDisplayWhenIdle=false\n\n' "$profile"
  printf '[%s][SuspendAndShutdown]\nAutoSuspendAction=0\n\n' "$profile"
done >/home/liveuser/.config/powerdevilrc
chown liveuser:liveuser /home/liveuser/.config/kscreenlockerrc /home/liveuser/.config/powerdevilrc

# Live session: passwordless root (Phase 1 only; the serial console autologins, see arch overlay).
passwd -d root

# P2-1: no Fedora branding. sddm-breeze (a hard dependency) ships the Fedora-named SDDM theme
# 01-breeze-fedora; drop that one directory. SDDM uses plain Breeze (desktop/ sets Current=breeze).
rm -rf /usr/share/sddm/themes/01-breeze-fedora
if compgen -G '/usr/share/sddm/themes/*fedora*' >/dev/null; then
  echo "Fedora-named SDDM theme still present" >&2; exit 1
fi
rm -f /etc/machine-id
touch /etc/machine-id
