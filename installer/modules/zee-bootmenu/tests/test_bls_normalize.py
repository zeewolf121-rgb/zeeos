# SPDX-License-Identifier: GPL-3.0-or-later
"""BLS entries copied from the kiwi image are pointed at the installed system (seen live: GRUB
could not find the kernel because the entry carried the CI build host's paths)."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bootmenu

VER = "7.2.11-200.fc44.aarch64"
KIWI_ENTRY = f"""title Fedora Linux ({VER}) 44 (Forty Four)
version {VER}
linux /home/runner/work/zeeos/zeeos/out/aarch64/image/build/image-root/boot/vmlinuz-{VER}
initrd /home/runner/work/zeeos/zeeos/out/aarch64/image/build/image-root/boot/initramfs-{VER}.img
options root=UUID=2b6f2f52-2550-42e1-be85-38102e250d03 ro rootflags=subvol=root console=tty0 console=ttyAMA0,115200 rd.live.image
grub_users $grub_users
grub_arg --unrestricted
grub_class fedora
"""
FSTAB = "UUID=dc3f4fcd-20c8-4939-93c1-40bfe834f389 / btrfs subvol=root,compress=zstd:1 0 0\nUUID=aaaa-bbbb /boot ext4 defaults 1 2\n"


class BlsNormalize(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "etc").mkdir()
        (self.root / "boot/loader/entries").mkdir(parents=True)
        self.entry = self.root / "boot/loader/entries" / f"abc-{VER}.conf"
        self.entry.write_text(KIWI_ENTRY)

    def tearDown(self):
        self.tmp.cleanup()

    def test_paths_and_root_point_at_the_installed_system(self):
        (self.root / "etc/fstab").write_text(FSTAB)
        new = bootmenu.bls_edits(self.root, None)[self.entry]
        self.assertIn(f"linux /vmlinuz-{VER}\n", new)
        self.assertIn(f"initrd /initramfs-{VER}.img\n", new)
        opts = next(l for l in new.splitlines() if l.startswith("options "))
        self.assertTrue(opts.startswith("options root=UUID=dc3f4fcd-20c8-4939-93c1-40bfe834f389 ro rootflags=subvol=root"), opts)
        self.assertNotIn("rd.live.image", opts)
        self.assertNotIn("2b6f2f52", opts)
        self.assertEqual(opts.count("root="), 1)
        self.assertIn("grub_class fedora", new)

    def test_console_is_applied_after_normalizing(self):
        (self.root / "etc/fstab").write_text(FSTAB)
        new = bootmenu.bls_edits(self.root, ["console=tty0", "console=ttyAMA0,115200"])[self.entry]
        opts = next(l for l in new.splitlines() if l.startswith("options "))
        self.assertEqual(opts.count("console=ttyAMA0,115200"), 1)
        self.assertIn("rootflags=subvol=root", opts)

    def test_luks_root_spec_is_kept_as_written(self):
        (self.root / "etc/fstab").write_text("/dev/mapper/luks-1234 / btrfs subvol=root 0 0\n")
        new = bootmenu.bls_edits(self.root, None)[self.entry]
        self.assertIn("options root=/dev/mapper/luks-1234 ro rootflags=subvol=root", new)

    def test_no_fstab_leaves_entries_alone(self):
        self.assertEqual(bootmenu.bls_edits(self.root, None), {})

    def test_title_names_zeeos(self):
        (self.root / "etc/fstab").write_text(FSTAB)
        new = bootmenu.bls_edits(self.root, None)[self.entry]
        self.assertIn(f"title ZeeOS ({VER})\n", new)
        self.assertNotIn("Fedora Linux", new)


class GrubCmdline(unittest.TestCase):
    """kiwi's /etc/default/grub has the live arguments; grub2-mkconfig copies them into the entries."""
    KIWI = 'GRUB_CMDLINE_LINUX="rd.live.image console=tty0 console=ttyAMA0"\n'

    def test_live_args_dropped_without_console(self):
        v = bootmenu.grub_values(self.KIWI, False)
        self.assertEqual(v["GRUB_CMDLINE_LINUX"], "console=tty0 console=ttyAMA0")

    def test_live_args_dropped_and_console_applied(self):
        v = bootmenu.grub_values(self.KIWI, False, ["console=tty0", "console=ttyAMA0,115200"])
        self.assertEqual(v["GRUB_CMDLINE_LINUX"], "console=tty0 console=ttyAMA0,115200")

    def test_clean_cmdline_untouched_without_console(self):
        self.assertNotIn("GRUB_CMDLINE_LINUX", bootmenu.grub_values('GRUB_CMDLINE_LINUX="rhgb quiet"\n', False))


if __name__ == "__main__":
    unittest.main()
