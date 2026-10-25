# SPDX-License-Identifier: GPL-3.0-or-later
"""Calamares job: apply the unattended CI preset to the target (P4-9, #181).

Only in the unattended sequence and only while /run/zeeos-autoinstall/preset.json exists. Creates
the preset user (wheel, password from the preset via chpasswd stdin, never on a command line or in
the log) and installs the test-only first-boot marker unit (zeeos-install-markers), which prints
ZEEOS_BOOTMENU, ZEEOS_ROOTFS and ZEEOS_DESKTOP_READY on the installed system. Interactive installs
never run this job, so they never get that unit. Writes only inside the target root, no disk
device. Dry run: globalstorage `zeeDryRun` true, or ZEE_DRY_RUN=1.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import libcalamares  # provided by Calamares at runtime

RUN = Path("/run/zeeos-autoinstall")
FIRSTBOOT = Path("/usr/share/zeeos/autoinstall/firstboot")
UNIT = "zeeos-install-markers.service"
SCRIPT = "zeeos-install-markers"


def pretty_name() -> str:
    return "Applying the unattended preset"


def fail(reason: str):
    try:
        (RUN / "fail").write_text(f"autopreset: {reason}\n")
    except OSError:
        pass
    return ("Unattended preset failed", reason)


def chroot(root: str, argv: list[str], dry: bool, stdin: str | None = None) -> None:
    libcalamares.utils.debug("zee-autopreset: chroot " + " ".join(argv) + (" (dry run)" if dry else ""))
    if dry:
        return
    r = subprocess.run(["chroot", root, *argv], input=stdin, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"{argv[0]} failed: {(r.stderr or r.stdout).strip()[:200]}")


def run():
    gs = libcalamares.globalstorage
    dry = bool(gs.value("zeeDryRun")) or os.environ.get("ZEE_DRY_RUN") == "1"
    root = gs.value("rootMountPoint")
    if not root:
        return fail("rootMountPoint is not set")
    try:
        preset = json.loads((RUN / "preset.json").read_text())
    except (OSError, ValueError):
        return fail("no unattended preset; this job only runs from zeeos-autoinstall")
    user = preset["user"]
    try:
        chroot(root, ["useradd", "-m", "-U", "-G", "wheel", "-s", "/bin/bash", user], dry)
        chroot(root, ["chpasswd"], dry, stdin=f"{user}:{preset['password']}\n")
        if not dry:
            Path(root, "etc/hostname").write_text("zeeos-autoinstall\n")
            dst_unit = Path(root, "usr/lib/systemd/system", UNIT)
            dst_bin = Path(root, "usr/libexec", SCRIPT)
            shutil.copy(FIRSTBOOT / UNIT, dst_unit)
            shutil.copy(FIRSTBOOT / SCRIPT, dst_bin)
            os.chmod(dst_unit, 0o644)
            os.chmod(dst_bin, 0o755)
        chroot(root, ["systemctl", "enable", UNIT], dry)
    except (OSError, RuntimeError, KeyError) as e:
        return fail(str(e))
    return None
