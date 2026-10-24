# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for zee-bootloader (P4-2, #176). unittest-based, stdlib only; pytest runs them too."""

from __future__ import annotations

import hashlib
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import shimgrub

UUID = "1b2c3d4e-0000-4000-8000-123456789abc"


def tree_digest(root: Path) -> str:
    """Hash of every path, mode and content under root."""
    h = hashlib.sha256()
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(dirs + files):
            p = Path(dirpath, name)
            h.update(f"{p.relative_to(root)}|{p.lstat().st_mode}|".encode())
            if p.is_file():
                h.update(p.read_bytes())
    return h.hexdigest()


def write(root: Path, files: dict[str, bytes]) -> None:
    for rel, data in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)


class ShimGrubTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.source, self.esp, self.root = t / "src", t / "esp", t / "root"
        write(self.source, {
            "shimx64.efi": b"MZ shim", "grubx64.efi": b"MZ grub", "mmx64.efi": b"MZ mm",
            "BOOTX64.CSV": b"shimx64.efi,Fedora", "grub.cfg": b"live stub", "README": b"x",
        })
        write(self.esp, {
            "EFI/Microsoft/Boot/bootmgfw.efi": b"MZ windows",
            "EFI/BOOT/BOOTX64.EFI": b"MZ windows fallback",
        })
        self.root.mkdir()
        self.calls = []

    def tearDown(self):
        self.tmp.cleanup()

    def install(self, **kw):
        kw.setdefault("log", lambda m: None)
        kw.setdefault("run", lambda cmd, root: self.calls.append((cmd, root)))
        return shimgrub.install(self.source, self.esp, self.root, boot_uuid=UUID, **kw)

    def test_copies_signed_files_and_writes_stub(self):
        self.install()
        dest = self.esp / "EFI/fedora"
        self.assertEqual(
            sorted(p.name for p in dest.iterdir()),
            ["BOOTX64.CSV", "grub.cfg", "grubx64.efi", "mmx64.efi", "shimx64.efi"],
        )
        self.assertEqual((dest / "shimx64.efi").read_bytes(), b"MZ shim")
        self.assertIn(f"--set=dev {UUID}", (dest / "grub.cfg").read_text())
        self.assertEqual(self.calls, [(["grub2-mkconfig", "-o", "/boot/grub2/grub.cfg"], self.root)])

    def test_windows_files_untouched(self):
        before = {p: tree_digest(self.esp / p) for p in ("EFI/Microsoft", "EFI/BOOT")}
        self.install()
        for p, d in before.items():
            self.assertEqual(tree_digest(self.esp / p), d, p)

    def test_dry_run_writes_nothing_and_logs_every_operation(self):
        before = tree_digest(self.esp)
        logs = []
        ops = self.install(dry_run=True, log=logs.append)
        self.assertEqual(tree_digest(self.esp), before)
        self.assertEqual(self.calls, [])
        self.assertEqual(len(ops), 1 + 4 + 2)  # mkdir, 4 copies, stub, grub2-mkconfig
        self.assertEqual(sum("plan:" in m for m in logs), len(ops))
        self.assertIn("dry run", logs[-1])

    def test_refuses_existing_fedora_dir(self):
        write(self.esp, {"EFI/fedora/shimx64.efi": b"another install"})
        before = tree_digest(self.esp)
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(tree_digest(self.esp), before)

    def test_missing_signed_binary_fails_before_writing(self):
        (self.source / "grubx64.efi").unlink()
        before = tree_digest(self.esp)
        with self.assertRaises(FileNotFoundError):
            self.install()
        self.assertEqual(tree_digest(self.esp), before)

    def test_aarch64_names_need_no_arch_setting(self):
        for f in self.source.iterdir():
            f.unlink()
        with self.assertRaises(FileNotFoundError):
            shimgrub.plan_files(self.source)
        write(self.source, {"shimaa64.efi": b"MZ", "grubaa64.efi": b"MZ"})
        self.assertEqual(shimgrub.plan_files(self.source), ["grubaa64.efi", "shimaa64.efi"])

    def test_bad_uuid_rejected(self):
        with self.assertRaises(ValueError):
            shimgrub.install(self.source, self.esp, self.root, boot_uuid="a b",
                             log=lambda m: None, run=lambda c, r: None)

    def test_cli_dry_run(self):
        before = tree_digest(self.esp)
        rc = shimgrub.main(["--dry-run", "--boot-uuid", UUID, str(self.source), str(self.esp), str(self.root)])
        self.assertEqual(rc, 0)
        self.assertEqual(tree_digest(self.esp), before)


if __name__ == "__main__":
    unittest.main()
