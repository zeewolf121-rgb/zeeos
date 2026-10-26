# SPDX-License-Identifier: GPL-3.0-or-later
"""Calamares job: back up the existing ESP to the target root before any bootloader write.

Runs after `mount` and before `bootloader` / `zee-bootmenu` in settings.conf. Logic and tests
live in espbackup.py. Dry run: globalstorage key `zeeDryRun` true, or ZEE_DRY_RUN=1.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import libcalamares  # provided by Calamares at runtime

# Calamares runs job scripts without __file__; it gives the module dir as job.working_path.
try:
    _HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    _HERE = libcalamares.job.working_path
sys.path.insert(0, _HERE)
import espbackup


def pretty_name() -> str:
    return "Backing up the EFI System Partition"


def find_esp(partitions: list[dict], root: str) -> Path | None:
    """The mounted ESP: the partition mounted at /boot/efi (Calamares' efiSystemPartition default)."""
    want = libcalamares.globalstorage.value("efiSystemPartition") or "/boot/efi"
    for p in partitions or []:
        if p.get("mountPoint") == want:
            return Path(root + want)
    return None


def run():
    gs = libcalamares.globalstorage
    root = gs.value("rootMountPoint")
    if not root:
        return ("No target root", "zee-espbackup: rootMountPoint is not set.")
    if gs.value("firmwareType") != "efi":
        libcalamares.utils.debug("zee-espbackup: BIOS install, no ESP to back up")
        return None
    esp = find_esp(gs.value("partitions"), root)
    if esp is None:
        return (
            "No EFI System Partition",
            "zee-espbackup: no partition is mounted as the ESP.",
        )
    dry = bool(gs.value("zeeDryRun")) or os.environ.get("ZEE_DRY_RUN") == "1"
    try:
        espbackup.backup(esp, Path(root), dry_run=dry, log=libcalamares.utils.debug)
    except (OSError, ValueError) as e:
        return (
            "ESP backup failed",
            f"zee-espbackup: {e}. Nothing was written to the ESP.",
        )
    return None
