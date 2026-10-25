# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for the unattended runner and the first-boot marker script (P4-9, #181). No disk is
opened and Calamares never runs: the runner is exercised in --dry-run mode on a preset file."""

import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[2] / "autoinstall"
RUNNER = HERE / "zeeos-autoinstall"
MARKERS = HERE / "firstboot" / "zeeos-install-markers"

loader = importlib.machinery.SourceFileLoader("zeeos_autoinstall", str(RUNNER))
spec = importlib.util.spec_from_loader("zeeos_autoinstall", loader)
ai = importlib.util.module_from_spec(spec)
loader.exec_module(ai)

GOOD = b"case=erase\nuser=zee\npassword=pw1\nluks_passphrase=lp\n"


class CalamaresConfigDir(unittest.TestCase):
    """`calamares -c DIR` makes DIR the app-data dir, and Calamares 3.3.14 aborts without DIR/qml."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.saved = (ai.RUN, ai.SHARE, ai.QML)
        ai.RUN, ai.SHARE, ai.QML = t / "run", t / "share", t / "qml"
        ai.SHARE.mkdir()
        (ai.SHARE / "settings.conf").write_text("sequence: []\n")

    def tearDown(self):
        ai.RUN, ai.SHARE, ai.QML = self.saved
        self.tmp.cleanup()

    def test_missing_qml_is_a_setup_problem(self):
        self.assertTrue(any("qml" in p for p in ai.setup_problems()))

    def test_config_dir_links_packaged_qml(self):
        ai.QML.mkdir()
        cfg = ai.config_dir()
        self.assertTrue((cfg / "qml").is_symlink())
        self.assertEqual((cfg / "qml").resolve(), ai.QML.resolve())
        self.assertTrue((cfg / "settings.conf").is_file())
        self.assertFalse(any("qml" in p for p in ai.setup_problems()))


class Preset(unittest.TestCase):
    def test_nul_padded(self):
        p = ai.parse_preset(GOOD + b"\0" * 4096 + b"case=luks\n")
        self.assertEqual(p, {"case": "erase", "user": "zee", "password": "pw1", "luks_passphrase": "lp"})

    def test_value_keeps_equals_signs(self):
        self.assertEqual(ai.parse_preset(b"case=erase\nuser=zee\npassword=a=b\n")["password"], "a=b")

    def test_rejects(self):
        bad = {
            "unknown key (e.g. a skip switch)": GOOD + b"skip=zee-preflight\n",
            "repeated key": GOOD + b"case=luks\n",
            "no case": b"user=zee\npassword=x\n",
            "bad case": b"case=wipe\nuser=zee\npassword=x\n",
            "root user": b"case=erase\nuser=root\npassword=x\n",
            "liveuser": b"case=erase\nuser=liveuser\npassword=x\n",
            "luks without passphrase": b"case=luks\nuser=zee\npassword=x\n",
            "not utf-8": b"case=erase\nuser=\xff\npassword=x\n",
            "empty disk": b"\0" * 1024,
        }
        for why, raw in bad.items():
            with self.subTest(why), self.assertRaises(ai.PresetError):
                ai.parse_preset(raw)

    def test_marker_case(self):
        self.assertEqual(ai.marker_case("refuse-bitlocker"), "refuse")
        self.assertEqual(ai.marker_case("luks"), "luks")

    def test_all_plan_cases_accepted(self):
        for c in ("erase", "luks", "alongside", "refuse-bitlocker", "refuse-hibernated"):
            ai.parse_preset(f"case={c}\nuser=zee\npassword=x\nluks_passphrase=y\n".encode())


def exec_jobs(settings: Path) -> list[str]:
    """The exec-phase job names of a Calamares settings.conf, in order (no YAML parser needed)."""
    jobs, in_exec = [], False
    for line in settings.read_text().splitlines():
        if line.startswith("  - "):
            in_exec = line.strip() == "- exec:"
        elif in_exec and line.startswith("      - "):
            jobs.append(line.strip()[2:])
    return jobs


class Sequence(unittest.TestCase):
    def test_disk_jobs_match_interactive(self):
        """The disk and boot jobs of the interactive install also run unattended, in the same
        order, with zee-preflight first and zee-autodone last."""
        unattended = exec_jobs(HERE / "settings.conf")
        interactive = exec_jobs(HERE.parent / "calamares" / "settings.conf")
        shared = ("mount", "unpackfs", "fstab", "dracut", "zee-espbackup", "zee-bootloader@zeeos",
                  "zee-bootmenu", "umount")
        self.assertEqual([j for j in interactive if j in shared], list(shared))
        self.assertEqual([j for j in unattended if j in shared], list(shared))
        self.assertEqual(unattended[0], "zee-preflight")
        self.assertEqual(unattended[-1], "zee-autodone")


class DryRun(unittest.TestCase):
    def run_runner(self, raw):
        with tempfile.NamedTemporaryFile() as f:
            f.write(raw)
            f.flush()
            env = dict(os.environ, ZEE_AUTOINSTALL_DEV=f.name)
            return subprocess.run([sys.executable, "-I", str(RUNNER), "--dry-run"], env=env,
                                  capture_output=True, text=True, timeout=30)

    def test_start_marker_and_no_action(self):
        r = self.run_runner(GOOD + b"\0" * 100)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ZEEOS_INSTALL_START case=erase", r.stdout)
        self.assertIn("dry run:", r.stdout)
        self.assertNotIn("ZEEOS_INSTALL_DONE", r.stdout)

    def test_missing_preflight_reported(self):
        if (ai.MODULES / "zee-preflight" / "module.desc").is_file():
            self.skipTest("zee-preflight installed on this host")
        r = self.run_runner(GOOD)
        self.assertIn("zee-preflight is not installed", r.stdout)

    def test_bad_preset_fails_with_marker(self):
        r = self.run_runner(b"case=wipe\nuser=zee\npassword=x\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("ZEEOS_INSTALL_FAIL preset:", r.stdout)


class Markers(unittest.TestCase):
    def run_markers(self, root):
        env = dict(os.environ, DRY_RUN="1", ROOT=str(root))
        return subprocess.run(["bash", str(MARKERS)], env=env, capture_output=True, text=True,
                              timeout=30).stdout

    def fixture(self, d, windows):
        root = Path(d)
        (root / "boot/loader/entries").mkdir(parents=True)
        (root / "boot/loader/entries/x.conf").write_text("title ZeeOS (6.17.0) 44\n")
        cfg = "menuentry 'Windows Boot Manager (on /dev/vda1)' {\n}\n" if windows else ""
        (root / "boot/grub2").mkdir(parents=True)
        (root / "boot/grub2/grub.cfg").write_text(cfg)
        (root / "etc/default").mkdir(parents=True)
        (root / "etc/default/grub").write_text('GRUB_TIMEOUT=5\nGRUB_DEFAULT="ZeeOS"\n')
        return root

    def test_bootmenu_alongside(self):
        with tempfile.TemporaryDirectory() as d:
            out = self.run_markers(self.fixture(d, True))
        self.assertIn("ZEEOS_BOOTMENU zeeos=1 windows=1 default=ZeeOS timeout=5", out)
        self.assertRegex(out, r"ZEEOS_ROOTFS fstype=\S+ luks=")

    def test_bootmenu_erase(self):
        with tempfile.TemporaryDirectory() as d:
            out = self.run_markers(self.fixture(d, False))
        self.assertIn("ZEEOS_BOOTMENU zeeos=1 windows=0", out)

    def test_empty_root(self):
        with tempfile.TemporaryDirectory() as d:
            out = self.run_markers(d)
        self.assertIn("ZEEOS_BOOTMENU zeeos=0 windows=0 default=0 timeout=unset", out)


if __name__ == "__main__":
    unittest.main()
