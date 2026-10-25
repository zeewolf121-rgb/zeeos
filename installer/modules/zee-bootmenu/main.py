# SPDX-License-Identifier: GPL-3.0-or-later
"""Calamares job: GRUB defaults, Windows entry, NVRAM entry ZeeOS (ADR-0004, P4-7 #179).

Runs after zee-bootloader. Logic and tests live in bootmenu.py. Dry run: globalstorage key
`zeeDryRun` true, or ZEE_DRY_RUN=1. ZeeOS goes first in BootOrder unless the module config's
`nvramFirst` or the globalstorage key `zeeNvramFirst` is false.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import libcalamares  # provided by Calamares at runtime

sys.path.insert(0, os.path.dirname(__file__))
import bootmenu


def pretty_name() -> str:
    return "Configuring the boot menu"


def run():
    gs = libcalamares.globalstorage
    conf = libcalamares.job.configuration or {}
    root = gs.value("rootMountPoint")
    if not root:
        return ("No target root", "zee-bootmenu: rootMountPoint is not set.")
    if gs.value("firmwareType") != "efi":
        return ("UEFI required", "zee-bootmenu: ZeeOS installs on UEFI systems only.")
    esp_mount = gs.value("efiSystemPartition") or "/boot/efi"
    esp = next((p for p in gs.value("partitions") or [] if p.get("mountPoint") == esp_mount), None)
    if not esp or not esp.get("device") or not esp.get("uuid"):
        return ("Missing partitions", "zee-bootmenu: no EFI system partition is mounted.")
    first = conf.get("nvramFirst", True) is not False and gs.value("zeeNvramFirst") is not False
    dry = bool(gs.value("zeeDryRun")) or os.environ.get("ZEE_DRY_RUN") == "1"
    try:
        bootmenu.install(
            Path(root + esp_mount),
            Path(root),
            esp_uuid=esp["uuid"],
            esp_device=esp["device"],
            first=first,
            dry_run=dry,
            log=libcalamares.utils.debug,
            run=target_output,
        )
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        return ("Boot menu configuration failed", f"zee-bootmenu: {e}")
    return None


def target_output(cmd: list[str]) -> str:
    """Run cmd in the target (Calamares chroots, efivars mounted); a non-zero exit raises
    subprocess.CalledProcessError and fails the job."""
    return libcalamares.utils.check_target_env_output(cmd)
