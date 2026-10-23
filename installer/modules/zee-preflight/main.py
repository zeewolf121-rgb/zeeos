# SPDX-License-Identifier: GPL-3.0-or-later
"""Calamares job: refuse to install when the plan touches a BitLocker volume.

Runs in exec before `partition`. Publishes the scan to globalstorage `zeePreflight`
for zee-summary. Configuration: `dryRun: true` logs every planned read.
"""
import libcalamares

import preflight


def pretty_name():
    return "Checking disks for BitLocker"


def run():
    conf = libcalamares.job.configuration or {}
    reader = preflight.Reader(dry_run=bool(conf.get("dryRun", False)))
    found, blocks = preflight.scan(preflight.candidates(), reader)
    for line in reader.log:
        libcalamares.utils.debug(line)
    libcalamares.globalstorage.insert("zeePreflight", {"devices": found, "resizeBlocked": bool(blocks)})

    planned = libcalamares.globalstorage.value("partitions") or []
    touched = [p["device"] for p in planned
               if p.get("mountPoint") and found.get(p.get("device")) in
               preflight.BLOCKING + (preflight.UNREADABLE,)]
    if touched:
        return ("BitLocker volume selected",
                "".join(preflight.FIX_STEPS.format(path=d, kind=found[d])
                        if found[d] in preflight.BLOCKING else
                        f"{d} could not be checked for BitLocker.\n" for d in touched))
    return None
