# SPDX-License-Identifier: GPL-3.0-or-later
"""Calamares job: unattended partitioning for CI presets (P4-9, #181). installer-disk.

Only in the unattended sequence (installer/autoinstall/settings.conf) and only while
zeeos-autoinstall's preset exists in /run/zeeos-autoinstall/. Cases `erase` and `luks` on a
blank disk; every other case is refused here (the refuse-* cases must already have stopped in
zee-preflight). Dry run: globalstorage key `zeeDryRun` true, or ZEE_DRY_RUN=1: prints the commands
and opens no disk.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import libcalamares  # provided by Calamares at runtime

sys.path.insert(0, os.path.dirname(__file__))
import autopart

RUN = Path("/run/zeeos-autoinstall")


def pretty_name() -> str:
    return "Partitioning the disk (unattended)"


def fail(reason: str):
    try:
        (RUN / "fail").write_text(f"autopart: {reason}\n")
    except OSError:
        pass
    return ("Unattended partitioning failed", reason)


def sh(argv: list[str], dry: bool, stdin: str | None = None) -> str:
    libcalamares.utils.debug("zee-autopart: " + " ".join(argv) + (" (dry run)" if dry else ""))
    if dry:
        return ""
    r = subprocess.run(argv, input=stdin, capture_output=True, text=True)
    if r.returncode:
        raise autopart.AutopartError(f"{argv[0]} failed: {(r.stderr or r.stdout).strip()[:200]}")
    return r.stdout.strip()


def blkid(dev: str, tag: str, dry: bool) -> str:
    return sh(["blkid", "-s", tag, "-o", "value", dev], dry) or f"DRY-{tag}"


def run():
    gs = libcalamares.globalstorage
    dry = bool(gs.value("zeeDryRun")) or os.environ.get("ZEE_DRY_RUN") == "1"
    try:
        preset = json.loads((RUN / "preset.json").read_text())
    except (OSError, ValueError):
        return fail("no unattended preset; this job only runs from zeeos-autoinstall")
    case = preset.get("case")
    if case not in ("erase", "luks"):
        return fail(f"case {case} is not partitioned unattended (erase and luks only)")
    if not os.path.isdir("/sys/firmware/efi"):
        return fail("UEFI required")
    gs.insert("firmwareType", "efi")
    gs.insert("efiSystemPartition", "/boot/efi")
    try:
        out = subprocess.run(
            ["lsblk", "-J", "-b", "-o",
             "NAME,PATH,TYPE,RM,RO,SERIAL,SIZE,PTTYPE,FSTYPE,MOUNTPOINTS"],
            capture_output=True, text=True, check=True).stdout
        disk = autopart.pick_disk(json.loads(out))
        autopart.check_blank(disk)
        path = disk["path"]
        sh(autopart.parted_argv(path), dry)
        sh(["udevadm", "settle"], dry)
        root = autopart.part_path(path, 3)
        luks_uuid = None
        if case == "luks":
            key = preset["luks_passphrase"]
            sh(["cryptsetup", "luksFormat", "--type", "luks2", "--batch-mode", "--key-file", "-",
                root], dry, stdin=key)
            luks_uuid = sh(["cryptsetup", "luksUUID", root], dry) or "DRY-LUKS"
            sh(["cryptsetup", "open", "--key-file", "-", root, autopart.mapper_name(luks_uuid)],
               dry, stdin=key)
            root = "/dev/mapper/" + autopart.mapper_name(luks_uuid)
        for argv in autopart.mkfs_argvs(path, root):
            sh(argv, dry)
        sh(["udevadm", "settle"], dry)
        devs = [autopart.part_path(path, n) for n in (1, 2, 3)] + ([root] if luks_uuid else [])
        ids = {d: {"uuid": blkid(d, "UUID", dry), "partuuid": blkid(d, "PARTUUID", dry)
                   if not d.startswith("/dev/mapper/") else ""} for d in devs}
        gs.insert("partitions", autopart.partitions_gs(path, ids, luks_uuid))
    except (autopart.AutopartError, subprocess.CalledProcessError, ValueError, KeyError) as e:
        return fail(str(e))
    return None
