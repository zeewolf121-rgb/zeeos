# SPDX-License-Identifier: GPL-3.0-or-later
"""The Calamares job (main.py) with a stand-in libcalamares: the unattended refusal writes the
`preflight: …` line zeeos-autoinstall turns into ZEEOS_INSTALL_FAIL (phase-4 marker protocol)."""
import importlib.util
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import preflight  # noqa: E402
from test_preflight import image, ntfs_image  # noqa: E402


class GlobalStorage(dict):
    def value(self, key):
        return self.get(key)

    def insert(self, key, value):
        self[key] = value


def load_job(tmp, gs, conf=None):
    """Import main.py the way Calamares does: no __file__, module dir in job.working_path."""
    lib = types.ModuleType("libcalamares")
    lib.globalstorage = gs
    lib.job = types.SimpleNamespace(configuration=conf or {}, working_path=str(HERE.parent))
    lib.utils = types.SimpleNamespace(debug=lambda msg: gs.setdefault("_log", []).append(msg))
    sys.modules["libcalamares"] = lib
    src = (HERE.parent / "main.py").read_text()
    mod = types.ModuleType("zee_preflight_job")
    exec(compile(src, str(HERE.parent / "main.py"), "exec"), mod.__dict__)  # no __file__ set
    mod.RUN = tmp / "run"
    return mod


class Job(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        (self.tmp / "run").mkdir()
        self.preset = self.tmp / "preset.img"
        self.preset.write_bytes(b"case=refuse-hibernated\n".ljust(4096, b"\0"))
        self.orig = preflight.candidates
        self.addCleanup(setattr, preflight, "candidates", self.orig)

    def devices(self, win):
        preflight.candidates = lambda: [
            {"path": win, "type": "part", "disk": "/dev/vda", "serial": ""},
            {"path": str(self.preset), "type": "disk", "disk": str(self.preset),
             "serial": "ZEEOS-AUTOINSTALL"}]

    def test_bitlocker_refused_with_marker_reason(self):
        win = image(self.tmp / "bl.img", b"-FVE-FS-", 160, 176)
        self.devices(win)
        gs = GlobalStorage()
        job = load_job(self.tmp, gs, {"dryRun": True})
        title, details = job.run()
        fail = (self.tmp / "run" / "fail").read_text()
        self.assertEqual(fail, f"preflight: refusing to resize or install: {win} is bitlocker\n")
        self.assertIn("recovery key", details)
        self.assertTrue(gs["zeePreflight"]["resizeBlocked"])
        self.assertTrue(any("PLAN read-only" in line for line in gs["_log"]))

    def test_dirty_refused(self):
        win = ntfs_image(self.tmp / "dirty.img", flags=preflight.VOLUME_IS_DIRTY)
        self.devices(win)
        job = load_job(self.tmp, GlobalStorage())
        self.assertIsNotNone(job.run())
        self.assertIn("is ntfs-dirty", (self.tmp / "run" / "fail").read_text())

    def test_clean_passes_and_writes_no_fail(self):
        win = image(self.tmp / "exfat.img", b"EXFAT   ")
        self.devices(win)
        gs = GlobalStorage()
        self.assertIsNone(load_job(self.tmp, gs).run())
        self.assertFalse((self.tmp / "run" / "fail").exists())
        self.assertEqual(gs["zeePreflight"]["touched"], [win])  # the preset disk never counts

    def test_runner_turns_the_fail_file_into_the_marker(self):
        spec = importlib.util.spec_from_loader("zeeos_autoinstall", loader=None)
        ai = importlib.util.module_from_spec(spec)
        runner = HERE.parents[2] / "autoinstall" / "zeeos-autoinstall"
        exec(compile(runner.read_text(), str(runner), "exec"), ai.__dict__)
        line = "preflight: refusing to resize or install: /dev/vda3 is ntfs-hibernated\n"
        self.assertEqual(f"ZEEOS_INSTALL_FAIL {ai.one_line(line)}",
                         "ZEEOS_INSTALL_FAIL preflight: refusing to resize or install: "
                         "/dev/vda3 is ntfs-hibernated")


if __name__ == "__main__":
    unittest.main()
