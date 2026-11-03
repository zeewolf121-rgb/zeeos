#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# kiwi-ng image config script: runs inside the image root at the end of the prepare step.
set -euxo pipefail

# kiwi writes the image type and profiles to /.profile. Live vs disk is an image-type difference, not
# an architecture difference, so it is gated here and not in build/arch/ (P5-5).
kiwi_type="" kiwi_profiles=""
# shellcheck disable=SC1091
[[ ! -f /.profile ]] || source /.profile
oem=0
if [[ "${kiwi_type:-}" == oem || ",${kiwi_profiles:-}," == *,oem,* ]]; then oem=1; fi

echo "ZeeOS" >/etc/hostname
systemctl set-default graphical.target
systemctl enable NetworkManager.service sddm.service zeeos-desktop-ready.service
# ADR-0012: firewall on everywhere; the update timer is enabled here and skipped in the live
# session by security/overlay's ConditionKernelCommandLine=!rd.live.image drop-in (not masked,
# so the system Calamares copies to disk runs it with no installer step).
systemctl enable firewalld.service dnf5-automatic.timer

if (( oem )); then
  # Installed-system disk (UTM): no live user, no autologin, no default password. The first user is
  # created on first boot by plasma-setup (plasma-setup.service runs before SDDM until
  # /etc/plasma-setup-done exists). Root is locked, as on Fedora.
  systemctl enable plasma-setup.service
  passwd -l root
  # Live-only files from the shared overlays: the liveuser SDDM autologin and the passwordless
  # root serial console.
  rm -f /etc/sddm.conf.d/10-zeeos-live-autologin.conf
  rm -f /etc/systemd/system/serial-getty@*.service.d/autologin.conf
  rmdir --ignore-fail-on-non-empty /etc/systemd/system/serial-getty@*.service.d 2>/dev/null || true
  if getent passwd liveuser >/dev/null; then echo "liveuser must not exist in the oem image" >&2; exit 1; fi
  [[ "$(passwd -S root | cut -d' ' -f2)" == L ]] || { echo "root must be locked in the oem image" >&2; exit 1; }
else
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
fi

# P2-1: no Fedora branding. sddm-breeze (a hard dependency) ships the Fedora-named SDDM theme
# 01-breeze-fedora; drop that one directory. SDDM uses plain Breeze (desktop/ sets Current=breeze).
rm -rf /usr/share/sddm/themes/01-breeze-fedora
if compgen -G '/usr/share/sddm/themes/*fedora*' >/dev/null; then
  echo "Fedora-named SDDM theme still present" >&2; exit 1
fi
rm -f /etc/machine-id
touch /etc/machine-id
