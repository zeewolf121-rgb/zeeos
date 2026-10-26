#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Stage the Calamares installer config and zee-* modules (owned by installer-engineer, /installer)
# into an image root. Every piece is skipped with a log line when its source does not exist yet.
# Usage: build/stage-installer.sh <repo-root> <image-root>
set -euo pipefail

repo="${1:?usage: stage-installer.sh <repo-root> <image-root>}"
dest="${2:?usage: stage-installer.sh <repo-root> <image-root>}"
cal="$repo/installer/calamares"

if [[ -f "$cal/settings.conf" ]]; then
  install -d -m 0755 "$dest/etc/calamares"
  install -m 0644 "$cal/settings.conf" "$dest/etc/calamares/settings.conf"
  echo "stage-installer: settings.conf -> /etc/calamares/settings.conf"
else
  echo "stage-installer: SKIP settings.conf (installer/calamares/settings.conf not present)"
fi

shopt -s nullglob
confs=("$cal"/modules/*.conf)
if ((${#confs[@]})); then
  install -d -m 0755 "$dest/etc/calamares/modules"
  install -m 0644 "${confs[@]}" "$dest/etc/calamares/modules/"
  echo "stage-installer: ${#confs[@]} module conf(s) -> /etc/calamares/modules/"
else
  echo "stage-installer: SKIP module confs (no installer/calamares/modules/*.conf)"
fi

if [[ -d "$cal/branding/zeeos" ]]; then
  install -d -m 0755 "$dest/etc/calamares/branding"
  rm -rf "${dest:?}/etc/calamares/branding/zeeos"
  cp -a "$cal/branding/zeeos" "$dest/etc/calamares/branding/zeeos"
  echo "stage-installer: branding/zeeos -> /etc/calamares/branding/zeeos/"
else
  echo "stage-installer: SKIP branding (installer/calamares/branding/zeeos not present)"
fi

mods=0
for m in "$repo"/installer/modules/zee-*/; do
  name="$(basename "$m")"
  install -d -m 0755 "$dest/usr/lib/calamares/modules"
  rm -rf "${dest:?}/usr/lib/calamares/modules/$name"
  cp -a "${m%/}" "$dest/usr/lib/calamares/modules/$name"
  rm -rf "${dest:?}/usr/lib/calamares/modules/$name/tests"
  find "$dest/usr/lib/calamares/modules/$name" -name __pycache__ -type d -prune -exec rm -rf {} +
  echo "stage-installer: module $name (without tests/) -> /usr/lib/calamares/modules/$name/"
  mods=$((mods + 1))
done
((mods)) || echo "stage-installer: SKIP zee-* modules (no installer/modules/zee-*/)"

# Unattended CI install (P4-9, #181): live unit, udev trigger, runner, its settings.conf and the
# first-boot marker unit that zee-autopreset copies to the target. Paths match the units and
# installer/calamares/modules/shellprocess-zeelivecleanup.conf, which removes them from the target.
ai="$repo/installer/autoinstall"
if [[ -f "$ai/zeeos-autoinstall" ]]; then
  install -d -m 0755 "$dest/usr/lib/systemd/system" "$dest/usr/lib/udev/rules.d" "$dest/usr/libexec" \
    "$dest/usr/share/zeeos/autoinstall/firstboot"
  install -m 0644 "$ai/zeeos-autoinstall.service" "$dest/usr/lib/systemd/system/"
  install -m 0644 "$ai/90-zeeos-autoinstall.rules" "$dest/usr/lib/udev/rules.d/"
  install -m 0755 "$ai/zeeos-autoinstall" "$dest/usr/libexec/zeeos-autoinstall"
  install -m 0644 "$ai/settings.conf" "$dest/usr/share/zeeos/autoinstall/settings.conf"
  install -m 0755 "$ai/firstboot/zeeos-install-markers" "$dest/usr/share/zeeos/autoinstall/firstboot/"
  install -m 0644 "$ai/firstboot/zeeos-install-markers.service" "$dest/usr/share/zeeos/autoinstall/firstboot/"
  echo "stage-installer: autoinstall unit, udev rule, runner, settings.conf and firstboot markers"
else
  echo "stage-installer: SKIP autoinstall (installer/autoinstall/zeeos-autoinstall not present)"
fi
