#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# kiwi-ng image config script: runs inside the image root at the end of the prepare step.
set -euxo pipefail

echo "ZeeOS" >/etc/hostname
systemctl set-default multi-user.target
systemctl enable NetworkManager.service

# Live session: passwordless root (Phase 1 only; the serial console autologins, see arch overlay).
passwd -d root
rm -f /etc/machine-id
touch /etc/machine-id
