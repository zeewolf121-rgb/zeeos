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
