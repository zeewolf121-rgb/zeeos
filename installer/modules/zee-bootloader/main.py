# SPDX-License-Identifier: GPL-3.0-or-later
"""Calamares job: Fedora's signed shim + GRUB on the target ESP (ADR-0004, P4-2 #176).

Runs after zee-espbackup, in place of Calamares' stock `bootloader` module. Logic and tests live
in shimgrub.py. Dry run: globalstorage key `zeeDryRun` true, or ZEE_DRY_RUN=1.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import libcalamares  # provided by Calamares at runtime

sys.path.insert(0, os.path.dirname(__file__))
import shimgrub


def pretty_name() -> str:
    return "Installing the signed boot loader"


def mounted_uuid(partitions: list[dict], mount_point: str) -> str | None:
    for p in partitions or []:
        if p.get("mountPoint") == mount_point:
            return p.get("uuid")
    return None


def run():
    gs = libcalamares.globalstorage
    conf = libcalamares.job.configuration or {}
    root = gs.value("rootMountPoint")
    if not root:
        return ("No target root", "zee-bootloader: rootMountPoint is not set.")
    if gs.value("firmwareType") != "efi":
        return ("UEFI required", "zee-bootloader: ZeeOS installs on UEFI systems only.")
    esp_mount = gs.value("efiSystemPartition") or "/boot/efi"
    partitions = gs.value("partitions")
    # Fedora's stub points at /boot; without a separate /boot (manual layouts) it points at /.
    boot_uuid = mounted_uuid(partitions, "/boot") or mounted_uuid(partitions, "/")
    if mounted_uuid(partitions, esp_mount) is None or not boot_uuid:
        return ("Missing partitions", "zee-bootloader: no ESP or no /boot / root partition.")
    dry = bool(gs.value("zeeDryRun")) or os.environ.get("ZEE_DRY_RUN") == "1"
    try:
        shimgrub.install(
            Path(conf.get("signedSource", "/boot/efi/EFI/fedora")),
            Path(root + esp_mount),
            Path(root),
            boot_uuid=boot_uuid,
            dry_run=dry,
            log=libcalamares.utils.debug,
            run=target_run,
        )
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        return ("Boot loader installation failed", f"zee-bootloader: {e}")
    return None


def target_run(cmd: list[str], _target_root: Path) -> None:
    """Run cmd in the target (Calamares chroots for us); a non-zero exit fails the job."""
    rc = libcalamares.utils.target_env_call(cmd)
    if rc != 0:
        raise subprocess.CalledProcessError(rc, cmd)
