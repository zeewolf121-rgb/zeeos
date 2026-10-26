# SPDX-License-Identifier: GPL-3.0-or-later
"""Calamares job: refuse to install when the plan touches a BitLocker, hibernated or dirty NTFS
volume, or one that can't be checked (P4-3 #4, P4-4 #5). installer-disk, but it never writes a disk.

Runs in exec before any disk job: first in the unattended sequence (zeeos-autoinstall), where no
plan exists yet, so every device except the preset disk counts as touched (preflight.touched).
On a refusal it writes `preflight: <reason>` to /run/zeeos-autoinstall/fail when that directory
exists, which zeeos-autoinstall prints as `ZEEOS_INSTALL_FAIL preflight: <reason>`.
Publishes the scan to globalstorage `zeePreflight`. Dry run (`dryRun: true` in the module config,
globalstorage `zeeDryRun`, or ZEE_DRY_RUN=1) logs every planned read; the probe is read-only
either way.
"""
import os
import subprocess
import sys
from pathlib import Path

import libcalamares

# Calamares runs job scripts without __file__; it gives the module dir as job.working_path.
try:
    _HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    _HERE = libcalamares.job.working_path
sys.path.insert(0, _HERE)

import preflight  # noqa: E402

RUN = Path("/run/zeeos-autoinstall")


def pretty_name():
    return "Checking disks for BitLocker and hibernated or dirty Windows volumes"


def fail(reason, details):
    if RUN.is_dir():
        try:
            (RUN / "fail").write_text(f"preflight: {reason}\n")
        except OSError:
            pass
    return ("Installation refused: a Windows volume is not safe to resize", details)


def run():
    conf = libcalamares.job.configuration or {}
    gs = libcalamares.globalstorage
    dry = (bool(conf.get("dryRun", False)) or bool(gs.value("zeeDryRun"))
           or os.environ.get("ZEE_DRY_RUN") == "1")
    reader = preflight.Reader(dry_run=dry)
    try:
        devices = preflight.candidates()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as e:
        return fail(f"cannot list disks ({e})", f"lsblk failed: {e}\n")
    found, _, why = preflight.scan([d["path"] for d in devices], reader)
    for line in reader.log:
        libcalamares.utils.debug("zee-preflight: " + line)
    # A plan entry without a device maps to no disk, so preflight.touched counts every disk.
    planned = [p.get("device") or "?" for p in gs.value("partitions") or []]
    paths = preflight.touched(devices, found, planned)
    verdict = preflight.refusal(found, why, paths)
    libcalamares.utils.debug(f"zee-preflight: found {found}; touched {paths}; dry run {dry}")
    gs.insert("zeePreflight", {"devices": found, "touched": paths, "resizeBlocked": bool(verdict)})
    if verdict:
        return fail(*verdict)
    return None
