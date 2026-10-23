# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for zee-espbackup (#177). unittest-based so `make lint` runs them without pytest; pytest runs them too."""

from __future__ import annotations

import datetime as dt
import hashlib
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import espbackup

NOW = dt.datetime(2026, 10, 23, 12, 0, 0, tzinfo=dt.UTC)


def tree_digest(root: Path) -> str:
    """Hash of every path, mode, mtime and content under root: any write to the ESP changes it."""
    h = hashlib.sha256()
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(dirs + files):
            p = Path(dirpath, name)
            st = p.lstat()
            h.update(f"{p.relative_to(root)}|{st.st_mode}|{st.st_mtime_ns}|".encode())
            if p.is_file():
                h.update(p.read_bytes())
    return h.hexdigest()


def windows_like_esp(esp: Path) -> None:
    """An ESP as Windows leaves it, plus a second loader: what an 'install alongside' meets."""
    files = {
        "EFI/Microsoft/Boot/bootmgfw.efi": b"MZ fake windows boot manager",
        "EFI/Microsoft/Boot/BCD": os.urandom(4096),
        "EFI/Microsoft/Recovery/BCD": b"recovery",
        "EFI/Boot/bootx64.efi": b"MZ fallback",
        "EFI/other-distro/grubx64.efi": b"MZ other",
    }
    for rel, data in files.items():
        p = esp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)


class EspBackupTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.esp, self.target = base / "esp", base / "target"
        self.esp.mkdir()
        self.target.mkdir()
        self.log: list[str] = []

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_backup(self, **kw):
        return espbackup.backup(
            self.esp, self.target, log=self.log.append, now=NOW, **kw
        )

    def test_backup_contents_and_manifest_match(self) -> None:
        windows_like_esp(self.esp)
        tar_path = self.run_backup()
        self.assertEqual(
            tar_path, self.target / "var/lib/zeeos/esp-backup-20261023T120000Z.tar"
        )
        with tarfile.open(tar_path) as tar:
            names = sorted(m.name for m in tar.getmembers())
            for m in tar.getmembers():
                self.assertEqual(
                    tar.extractfile(m).read(), (self.esp / m.name).read_bytes(), m.name
                )
        self.assertEqual(
            names, sorted(p.as_posix() for p in espbackup.esp_files(self.esp))
        )
        sums = (
            (self.target / "var/lib/zeeos/esp-backup-20261023T120000Z.sha256")
            .read_text()
            .splitlines()
        )
        self.assertEqual(len(sums), 5)
        for line in sums:
            digest, rel = line.split("  ", 1)
            self.assertEqual(
                digest, hashlib.sha256((self.esp / rel).read_bytes()).hexdigest()
            )

    def test_esp_unchanged(self) -> None:
        windows_like_esp(self.esp)
        before = tree_digest(self.esp)
        self.run_backup()
        self.assertEqual(tree_digest(self.esp), before)

    def test_backup_files_are_private(self) -> None:
        windows_like_esp(self.esp)
        tar_path = self.run_backup()
        self.assertEqual(tar_path.stat().st_mode & 0o777, 0o600)

    def test_dry_run_writes_nothing_and_logs_every_operation(self) -> None:
        windows_like_esp(self.esp)
        before_esp, before_target = tree_digest(self.esp), tree_digest(self.target)
        self.assertIsNone(self.run_backup(dry_run=True))
        self.assertEqual(tree_digest(self.esp), before_esp)
        self.assertEqual(tree_digest(self.target), before_target)
        plan = [m for m in self.log if ": plan: " in m]
        self.assertEqual(len(plan), 4, self.log)
        self.assertTrue(any("read 5 files" in m and "read-only" in m for m in plan))
        self.assertTrue(any("dry run, nothing written" in m for m in self.log))

    def test_empty_esp_writes_nothing(self) -> None:
        self.assertIsNone(self.run_backup())
        self.assertFalse((self.target / "var").exists())

    def test_missing_esp_fails(self) -> None:
        with self.assertRaises(FileNotFoundError):
            espbackup.backup(self.esp / "nope", self.target, log=self.log.append)

    def test_refuses_target_on_the_esp(self) -> None:
        windows_like_esp(self.esp)
        before = tree_digest(self.esp)
        for target in (self.esp, self.esp / "EFI"):
            with self.assertRaises(ValueError):
                espbackup.backup(self.esp, target, log=self.log.append)
        self.assertEqual(tree_digest(self.esp), before)

    def test_cli_dry_run(self) -> None:
        windows_like_esp(self.esp)
        self.assertEqual(
            espbackup.main(["--dry-run", str(self.esp), str(self.target)]), 0
        )
        self.assertFalse((self.target / "var").exists())


if __name__ == "__main__":
    unittest.main()
