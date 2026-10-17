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
rm -f /etc/machine-id
touch /etc/machine-id
