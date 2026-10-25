# SPDX-License-Identifier: GPL-3.0-or-later
"""Calamares job: last job of the unattended sequence (P4-9, #181). Touches no disk.

Tells zeeos-autoinstall that every job before it succeeded, so ZEEOS_INSTALL_DONE never depends on
how Calamares happens to exit.
"""

from pathlib import Path

RUN = Path("/run/zeeos-autoinstall")


def pretty_name() -> str:
    return "Finishing the unattended install"


def run():
    if not RUN.is_dir():
        return ("Not unattended", "zee-autodone only runs from zeeos-autoinstall.")
    (RUN / "done").write_text("done\n")
    return None
