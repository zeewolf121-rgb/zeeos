# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for zee-bootmenu (#179) with a fake ESP and a fake efibootmgr. unittest-based so
`make lint` runs them without pytest; pytest runs them too."""

from __future__ import annotations

import hashlib
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bootmenu

UUID = "1A2B-3C4D"
FEDORA_DEFAULTS = (
    'GRUB_TIMEOUT=1\n'
    'GRUB_DISTRIBUTOR="$(sed \'s, release .*$,,g\' /etc/system-release)"\n'
    'GRUB_DEFAULT=saved\n'
    'GRUB_DISABLE_SUBMENU=true\n'
    'GRUB_TERMINAL_OUTPUT="console"\n'
    'GRUB_CMDLINE_LINUX="rhgb quiet"\n'
    'GRUB_DISABLE_RECOVERY="true"\n'
    'GRUB_ENABLE_BLSCFG=true\n'
)


def tree_digest(root: Path) -> str:
    """Hash of every path, mode, mtime and content under root: any write changes it."""
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


class FakeEfibootmgr:
    """NVRAM as a dict, driven through the same commands the job sends to the target."""

    def __init__(self, entries: dict[str, str], order: list[str], *, evil: bool = False):
        self.entries, self.order, self.evil = dict(entries), list(order), evil
        self.calls: list[list[str]] = []

    def listing(self) -> str:
        lines = ["BootCurrent: 0001", "Timeout: 0 seconds", "BootOrder: " + ",".join(self.order)]
        lines += [f"Boot{n}* {label}\tHD(1,GPT,...)/File(...)" for n, label in sorted(self.entries.items())]
        return "\n".join(lines) + "\n"

    def __call__(self, cmd: list[str]) -> str:
        self.calls.append(cmd)
        if cmd[0] != "efibootmgr":
            return ""
        if "--create" in cmd:
            n = f"{max(int(x, 16) for x in self.entries) + 1:04X}" if self.entries else "0000"
            self.entries[n] = cmd[cmd.index("--label") + 1]
            self.order.insert(0, n)  # what the real efibootmgr --create does
            if self.evil:  # a broken firmware/tool: must be detected, not ignored
                self.entries.pop("0000", None)
        elif "--bootorder" in cmd:
            self.order = cmd[cmd.index("--bootorder") + 1].split(",")
        return self.listing()

    def writes(self) -> list[list[str]]:
        return [c for c in self.calls if c != ["efibootmgr"]]


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name, "target")
        self.esp = self.root / "boot/efi"
        files = {
            "EFI/Microsoft/Boot/bootmgfw.efi": b"MZ fake windows boot manager",
            "EFI/Microsoft/Boot/BCD": b"\x00" * 4096,
            "EFI/BOOT/BOOTX64.EFI": b"MZ windows fallback",
            "EFI/fedora/shimx64.efi": b"MZ shim",
            "EFI/fedora/shim.efi": b"MZ shim",
            "EFI/fedora/grubx64.efi": b"MZ grub",
            "EFI/fedora/mmx64.efi": b"MZ mm",
        }
        for rel, data in files.items():
            (self.esp / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.esp / rel).write_bytes(data)
        (self.root / "etc/default").mkdir(parents=True)
        (self.root / "etc/default/grub").write_text(FEDORA_DEFAULTS)
        self.nvram = FakeEfibootmgr(
            {"0000": "Windows Boot Manager", "0001": "UEFI QEMU DVD-ROM", "0002": "EFI Internal Shell"},
            ["0000", "0001", "0002"],
        )
        self.log: list[str] = []

    def install(self, **kw):
        args = dict(esp_uuid=UUID, esp_device="/dev/vda1", log=self.log.append, run=self.nvram)
        args.update(kw)
        return bootmenu.install(self.esp, self.root, **args)

    def defaults(self) -> dict[str, str]:
        text = (self.root / "etc/default/grub").read_text()
        return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


class DryRun(Fixture):
    def test_logs_every_operation_and_writes_nothing(self):
        esp, target = tree_digest(self.esp), tree_digest(self.root)
        ops = self.install(dry_run=True)
        self.assertEqual(tree_digest(self.esp), esp)
        self.assertEqual(tree_digest(self.root), target)
        self.assertEqual(self.nvram.writes(), [], "dry run only lists NVRAM")
        self.assertEqual(len(self.nvram.entries), 3)
        planned = [line for line in self.log if line.startswith("zee-bootmenu: plan: ")]
        self.assertEqual(planned, [f"zee-bootmenu: plan: {op}" for op in ops])
        text = "\n".join(ops)
        for needle in ("GRUB_DEFAULT=0", "GRUB_TIMEOUT=5", "GRUB_DISABLE_OS_PROBER=false",
                       "35_zeeos_windows", f"ESP UUID {UUID}", "grub2-mkconfig -o /boot/grub2/grub.cfg",
                       "--disk /dev/vda --part 1 --label ZeeOS --loader \\EFI\\fedora\\shimx64.efi",
                       "ZeeOS first, then 0000,0001,0002 unchanged"):
            self.assertIn(needle, text)
        self.assertIn("zee-bootmenu: dry run, nothing written", self.log)

    def test_planned_ops_are_ascii(self):
        self.assertTrue(all(op.isascii() for op in self.install(dry_run=True)))


class Install(Fixture):
    def test_full_install_alongside_windows(self):
        esp = tree_digest(self.esp)
        self.install()
        self.assertEqual(tree_digest(self.esp), esp, "the ESP, \\EFI\\Microsoft\\ included, is untouched")

        d = self.defaults()
        self.assertEqual(d["GRUB_DEFAULT"], '"0"')
        self.assertEqual(d["GRUB_TIMEOUT"], '"5"')
        self.assertEqual(d["GRUB_TIMEOUT_STYLE"], '"menu"')
        self.assertEqual(d["GRUB_DISABLE_OS_PROBER"], '"false"')
        self.assertEqual(d["GRUB_CMDLINE_LINUX"], '"rhgb quiet"', "unrelated keys are kept")
        self.assertEqual(d["GRUB_ENABLE_BLSCFG"], "true")
        self.assertNotIn("GRUB_THEME", d)

        script = self.root / bootmenu.WINDOWS_SCRIPT
        self.assertTrue(os.access(script, os.X_OK))
        body = script.read_text()
        self.assertTrue(body.isascii())
        self.assertIn(f"search --no-floppy --fs-uuid --set=root {UUID}", body)
        self.assertIn("chainloader /EFI/Microsoft/Boot/bootmgfw.efi", body)

        cmds = [c[0] for c in self.nvram.calls]
        self.assertLess(cmds.index("grub2-editenv"), cmds.index("grub2-mkconfig"))
        self.assertIn(["grub2-mkconfig", "-o", "/boot/grub2/grub.cfg"], self.nvram.calls)

        self.assertEqual(self.nvram.entries["0003"], "ZeeOS")
        self.assertEqual(self.nvram.entries["0000"], "Windows Boot Manager", "Windows Boot Manager kept")
        self.assertEqual(self.nvram.order, ["0003", "0000", "0001", "0002"])
        self.assertFalse(any("--delete-bootnum" in c or "-B" in c for c in self.nvram.calls))
        create = next(c for c in self.nvram.calls if "--create" in c)
        self.assertEqual(create[create.index("--loader") + 1], "\\EFI\\fedora\\shimx64.efi")

    def test_not_first_appends_and_keeps_the_order(self):
        self.install(first=False)
        self.assertEqual(self.nvram.order, ["0000", "0001", "0002", "0003"])

    def test_no_windows_no_static_entry(self):
        (self.esp / bootmenu.WINDOWS_LOADER).unlink()
        self.install()
        self.assertFalse((self.root / bootmenu.WINDOWS_SCRIPT).exists())
        self.assertEqual(self.defaults()["GRUB_DISABLE_OS_PROBER"], '"false"')

    def test_theme_copied_to_boot_and_enabled(self):
        theme = self.root / bootmenu.THEME_SOURCE
        theme.mkdir(parents=True)
        (theme / "theme.txt").write_text("title-text: \"\"\n")
        (theme / "background.png").write_bytes(b"\x89PNG")
        (self.root / "etc/default/grub").write_text(FEDORA_DEFAULTS.replace('"console"', '"console serial"'))
        self.install()
        self.assertTrue((self.root / bootmenu.THEME_DEST / "background.png").is_file())
        d = self.defaults()
        self.assertEqual(d["GRUB_THEME"], '"/boot/grub2/themes/zeeos/theme.txt"')
        self.assertEqual(d["GRUB_TERMINAL_OUTPUT"], '"gfxterm serial"', "serial console kept")

    def test_missing_defaults_file_gets_bls(self):
        (self.root / "etc/default/grub").unlink()
        self.install()
        self.assertEqual(self.defaults()["GRUB_ENABLE_BLSCFG"], '"true"')

    def test_existing_zeeos_entry_is_kept(self):
        self.nvram.entries["0004"] = "ZeeOS"
        self.nvram.order.append("0004")
        self.install()
        self.assertEqual(self.nvram.entries["0004"], "ZeeOS")
        self.assertEqual(self.nvram.order, ["0005", "0000", "0001", "0002", "0004"])

    def test_lost_windows_entry_fails_the_job(self):
        self.nvram.evil = True
        with self.assertRaisesRegex(ValueError, "Windows Boot Manager"):
            self.install()


class Refusals(Fixture):
    def test_bad_uuid_refused_before_any_write(self):
        target = tree_digest(self.root)
        for bad in ("", "1A2B-3C4D\nmenuentry x", "$(reboot)", "a b"):
            with self.assertRaises(ValueError):
                self.install(esp_uuid=bad)
        self.assertEqual(tree_digest(self.root), target)
        self.assertEqual(self.nvram.calls, [])

    def test_missing_shim_refused(self):
        (self.esp / "EFI/fedora/shimx64.efi").unlink()
        with self.assertRaisesRegex(FileNotFoundError, "shim"):
            self.install()
        self.assertEqual(self.nvram.writes(), [])

    def test_no_esp(self):
        with self.assertRaises(FileNotFoundError):
            bootmenu.install(self.root / "nope", self.root, esp_uuid=UUID, esp_device="/dev/vda1",
                             run=self.nvram)


class Helpers(unittest.TestCase):
    def test_split_device(self):
        cases = {"/dev/vda1": ("/dev/vda", "1"), "/dev/sdb12": ("/dev/sdb", "12"),
                 "/dev/nvme0n1p1": ("/dev/nvme0n1", "1"), "/dev/mmcblk0p2": ("/dev/mmcblk0", "2")}
        for dev, want in cases.items():
            self.assertEqual(bootmenu.split_device(dev), want)
        with self.assertRaises(ValueError):
            bootmenu.split_device("/dev/vda")

    def test_edit_defaults_replaces_duplicates_and_keeps_comments(self):
        out = bootmenu.edit_defaults("# c\nGRUB_TIMEOUT=1\nX=1\nGRUB_TIMEOUT=2\n", {"GRUB_TIMEOUT": "5"})
        self.assertEqual(out, '# c\nGRUB_TIMEOUT="5"\nX=1\n')

    def test_parse_efibootmgr(self):
        nv = bootmenu.parse_efibootmgr(
            "BootCurrent: 0001\nBootOrder: 0000,000a\nBoot0000* Windows Boot Manager\tHD(1)\nBoot000A  Off\n")
        self.assertEqual(nv.order, ["0000", "000A"])
        self.assertEqual(nv.labels, {"0000": "Windows Boot Manager", "000A": "Off"})


BLS_ENTRY = ("title ZeeOS (6.17.0) 44\nversion 6.17.0\nlinux /vmlinuz-6.17.0\n"
             "options root=UUID=abcd ro rhgb quiet\ngrub_users $grub_users\n")


class Console(Fixture):
    """Unattended CI installs only (#250): console= from the preset reaches the kernel."""

    def setUp(self):
        super().setUp()
        self.bls = self.root / "boot/loader/entries/abc-6.17.0.conf"
        self.bls.parent.mkdir(parents=True)
        self.bls.write_text(BLS_ENTRY)

    def test_without_console_nothing_changes(self):
        self.install()
        self.assertEqual(self.defaults()["GRUB_CMDLINE_LINUX"], '"rhgb quiet"')
        self.assertEqual(self.bls.read_text(), BLS_ENTRY)

    def test_console_in_defaults_and_bls(self):
        self.install(console="tty0 ttyS0,115200")
        self.assertEqual(self.defaults()["GRUB_CMDLINE_LINUX"], '"console=tty0 console=ttyS0,115200"')
        text = self.bls.read_text()
        self.assertIn("options root=UUID=abcd ro console=tty0 console=ttyS0,115200\n", text)
        self.assertEqual(text.replace("options root=UUID=abcd ro console=tty0 console=ttyS0,115200",
                                      "options root=UUID=abcd ro rhgb quiet"), BLS_ENTRY,
                         "only the options line changes")
        self.assertEqual(self.defaults()["GRUB_TIMEOUT"], '"5"', "the other defaults still apply")

    def test_existing_console_replaced_not_doubled(self):
        (self.root / "etc/default/grub").write_text(
            FEDORA_DEFAULTS.replace('"rhgb quiet"', '"rd.lvm=0 console=ttyS1 rhgb quiet"'))
        self.bls.write_text(BLS_ENTRY.replace("ro rhgb", "ro console=tty1 rhgb"))
        self.install(console="ttyAMA0,115200")
        self.assertEqual(self.defaults()["GRUB_CMDLINE_LINUX"], '"rd.lvm=0 console=ttyAMA0,115200"')
        self.assertIn("options root=UUID=abcd ro console=ttyAMA0,115200\n", self.bls.read_text())

    def test_dry_run_plans_and_writes_nothing(self):
        target = tree_digest(self.root)
        ops = self.install(console="tty0 ttyS0,115200", dry_run=True)
        self.assertEqual(tree_digest(self.root), target)
        text = "\n".join(ops)
        self.assertIn("GRUB_CMDLINE_LINUX=console=tty0 console=ttyS0,115200", text)
        self.assertIn(f"write {self.bls}: options with console=tty0 console=ttyS0,115200", text)

    def test_bad_console_refused_before_any_write(self):
        target = tree_digest(self.root)
        for bad in ("ttyS0;reboot", "ttyUSB0", "ttyS0,115200n8", "tty0  ttyS0", " ttyS0", "ttyS0\n",
                    "ttyS0 init=/bin/sh"):
            with self.subTest(bad), self.assertRaises(ValueError):
                self.install(console=bad)
        self.assertEqual(tree_digest(self.root), target)
        self.assertEqual(self.nvram.writes(), [])

    def test_same_pattern_as_the_preset_parser(self):
        runner = Path(__file__).resolve().parents[3] / "autoinstall/zeeos-autoinstall"
        self.assertIn(f're.compile(r"{bootmenu.CONSOLE.pattern}")', runner.read_text())


LUKS = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"


class Luks(Fixture):
    """Root on LUKS2 (#254): the initramfs only asks for the passphrase if rd.luks.uuid= names the container."""

    def setUp(self):
        super().setUp()
        self.bls = self.root / "boot/loader/entries/abc-6.17.0.conf"
        self.bls.parent.mkdir(parents=True)
        self.bls.write_text(BLS_ENTRY)

    def test_mapper_source_adds_rd_luks_uuid_to_grub_and_bls(self):
        seen = []
        self.install(console="tty0 ttyS0,115200",
                     root_source=lambda r: seen.append(r) or f"/dev/mapper/luks-{LUKS}[/root]")
        self.assertEqual(seen, [self.root])
        self.assertEqual(self.defaults()["GRUB_CMDLINE_LINUX"],
                         f'"console=tty0 console=ttyS0,115200 rd.luks.uuid={LUKS}"')
        self.assertIn(f"options root=UUID=abcd ro console=tty0 console=ttyS0,115200 rd.luks.uuid={LUKS}\n",
                      self.bls.read_text())

    def test_without_console_still_added(self):
        self.install(root_source=lambda r: f"/dev/mapper/luks-{LUKS}")
        self.assertEqual(self.defaults()["GRUB_CMDLINE_LINUX"], f'"rhgb quiet rd.luks.uuid={LUKS}"')
        self.assertIn(f"rhgb quiet rd.luks.uuid={LUKS}\n", self.bls.read_text())

    def test_crypttab_wins_and_is_enough(self):
        (self.root / "etc/crypttab").write_text(f"luks-{LUKS.upper()} UUID={LUKS.upper()} none discard\n")
        self.install()
        self.assertEqual(self.defaults()["GRUB_CMDLINE_LINUX"], f'"rhgb quiet rd.luks.uuid={LUKS}"')

    def test_root_mount_beats_an_earlier_crypttab_volume(self):
        other = "0f0f0f0f-1111-2222-3333-444444444444"
        (self.root / "etc/crypttab").write_text(
            f"luks-{other} UUID={other} none\nluks-{LUKS} UUID={LUKS} none\n")
        self.install(root_source=lambda r: f"/dev/mapper/luks-{LUKS}[/root]")
        self.assertIn(f"rd.luks.uuid={LUKS}", self.defaults()["GRUB_CMDLINE_LINUX"])
        self.assertNotIn(other, self.defaults()["GRUB_CMDLINE_LINUX"])

    def test_custom_mapper_name_matched_in_crypttab(self):
        other = "0f0f0f0f-1111-2222-3333-444444444444"
        (self.root / "etc/crypttab").write_text(f"homecrypt UUID={other} none\nrootcrypt UUID={LUKS} none\n")
        self.install(root_source=lambda r: "/dev/mapper/rootcrypt[/root]")
        self.assertIn(f"rd.luks.uuid={LUKS}", self.defaults()["GRUB_CMDLINE_LINUX"])
        self.assertNotIn(other, self.defaults()["GRUB_CMDLINE_LINUX"])

    def test_ambiguous_crypttab_without_root_info_adds_nothing(self):
        other = "0f0f0f0f-1111-2222-3333-444444444444"
        (self.root / "etc/crypttab").write_text(f"luks-{other} UUID={other} none\nluks-{LUKS} UUID={LUKS} none\n")
        self.install()
        self.assertNotIn("rd.luks.uuid", self.defaults().get("GRUB_CMDLINE_LINUX", ""))

    def test_idempotent(self):
        src = lambda r: f"/dev/mapper/luks-{LUKS}[/root]"
        self.install(root_source=src)
        first = (self.root / "etc/default/grub").read_text(), self.bls.read_text()
        self.install(root_source=src)
        self.assertEqual(((self.root / "etc/default/grub").read_text(), self.bls.read_text()), first)
        self.assertEqual(self.defaults()["GRUB_CMDLINE_LINUX"].count("rd.luks.uuid="), 1)

    def test_plain_root_has_no_rd_luks_uuid(self):
        for src in (lambda r: "/dev/vda3[/root]", lambda r: "/dev/mapper/vg-root", lambda r: "", None):
            with self.subTest(src=src):
                self.install(root_source=src)
                self.assertNotIn("rd.luks", (self.root / "etc/default/grub").read_text())
                self.assertEqual(self.bls.read_text(), BLS_ENTRY)

    def test_dry_run_plans_and_writes_nothing(self):
        target = tree_digest(self.root)
        self.install(dry_run=True, root_source=lambda r: f"/dev/mapper/luks-{LUKS}")
        self.assertEqual(tree_digest(self.root), target)
        self.assertTrue(any("rd.luks.uuid" in l for l in self.log))


if __name__ == "__main__":
    unittest.main()
