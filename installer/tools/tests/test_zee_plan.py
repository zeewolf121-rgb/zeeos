# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for the P4-2 dry-run planner and the shipped Calamares config (#176). unittest, needs PyYAML."""

from __future__ import annotations

import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("zee_plan", HERE.parent / "zee-plan.py")
zee_plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zee_plan)
CALAMARES = zee_plan.INSTALLER / "calamares"


class ShippedConfigTest(unittest.TestCase):
    def test_every_mode_plans_cleanly(self):
        for mode in ("erase", "alongside", "manual"):
            for luks in (False, True):
                lines = zee_plan.plan(CALAMARES, mode, luks)
                self.assertEqual(lines[-1], "zee-plan: dry run, no disk opened")
                for step in ("partition", "unpackfs", "zee-espbackup", "zee-bootloader@zeeos"):
                    self.assertTrue(any(f": {step}: " in l for l in lines), (mode, step))

    def test_luks_only_with_automated_partitioning(self):
        self.assertTrue(any("LUKS2" in l for l in zee_plan.plan(CALAMARES, "erase", True)))
        self.assertFalse(any("LUKS2" in l for l in zee_plan.plan(CALAMARES, "erase", False)))

    def test_espbackup_runs_before_the_bootloader(self):
        steps = zee_plan.exec_steps(zee_plan.load(CALAMARES / "settings.conf"))
        self.assertLess(steps.index("zee-espbackup"), steps.index("zee-bootloader@zeeos"))
        self.assertNotIn("bootloader", steps)

    def test_cli(self):
        self.assertEqual(zee_plan.main(["--mode", "alongside", "--luks"]), 0)


class BrokenConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cal = Path(self.tmp.name) / "calamares"
        shutil.copytree(CALAMARES, self.cal)

    def tearDown(self):
        self.tmp.cleanup()

    def edit(self, rel: str, old: str, new: str) -> None:
        p = self.cal / rel
        text = p.read_text()
        self.assertIn(old, text)
        p.write_text(text.replace(old, new, 1))

    def assertFails(self, msg: str) -> None:
        with self.assertRaisesRegex(zee_plan.PlanError, msg):
            zee_plan.check(self.cal)

    def test_autologin_on_fails(self):
        self.edit("modules/users.conf", "doAutologin: false", "doAutologin: true")
        self.assertFails("doAutologin")

    def test_stock_bootloader_fails(self):
        self.edit("settings.conf", "      - zee-bootloader@zeeos", "      - bootloader")
        self.assertFails("not allowed")

    def test_backup_after_bootloader_fails(self):
        self.edit("settings.conf", "      - zee-espbackup\n", "")
        self.edit("settings.conf", "      - umount", "      - zee-espbackup\n      - umount")
        self.assertFails("exec order")

    def test_luks1_fails(self):
        self.edit("modules/partition.conf", "luksGeneration: luks2", "luksGeneration: luks1")
        self.assertFails("luks2")

    def test_esp_copied_by_unpackfs_fails(self):
        self.edit("modules/unpackfs.conf", '      - "/boot/efi/*"\n', "")
        self.assertFails("boot/efi")

    def test_cleanup_missing_autologin_fails(self):
        self.edit("modules/shellprocess-zeelivecleanup.conf",
                  '  - "rm -f /etc/sddm.conf.d/10-zeeos-live-autologin.conf"\n', "")
        # The final check line still names the file, so drop it there too.
        self.edit("modules/shellprocess-zeelivecleanup.conf", "/etc/sddm.conf.d/10-zeeos-live-autologin.conf ", "")
        self.assertFails("10-zeeos-live-autologin")

    def test_unknown_module_fails(self):
        self.edit("settings.conf", "      - hwclock", "      - nosuchmodule")
        self.assertFails("unknown module")


if __name__ == "__main__":
    unittest.main()
