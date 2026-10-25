# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for zee-autopart's pure logic (P4-9, #181). No disk is opened."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import autopart  # noqa: E402

GiB = 1 << 30


def disk(name, **kw):
    d = {"name": name, "path": f"/dev/{name}", "type": "disk", "rm": False, "ro": False,
         "serial": None, "size": 40 * GiB, "pttype": None, "fstype": None, "mountpoints": [None]}
    d.update(kw)
    return d


LIVE = {"name": "sr0", "path": "/dev/sr0", "type": "rom", "rm": True, "ro": False,
        "mountpoints": ["/run/initramfs/live"]}
PRESET = disk("vdb", serial="ZEEOS-AUTOINSTALL", size=1 << 20, ro=True)


class PickDisk(unittest.TestCase):
    def test_picks_the_only_target(self):
        got = autopart.pick_disk({"blockdevices": [LIVE, disk("vda"), PRESET,
                                                   disk("zram0", size=GiB)]})
        self.assertEqual(got["path"], "/dev/vda")

    def test_preset_disk_never_picked_even_if_writable(self):
        p = dict(PRESET, ro=False)
        with self.assertRaises(autopart.AutopartError):
            autopart.pick_disk({"blockdevices": [p]})

    def test_two_candidates_refused(self):
        with self.assertRaisesRegex(autopart.AutopartError, "exactly one"):
            autopart.pick_disk({"blockdevices": [disk("vda"), disk("vdc")]})

    def test_disk_in_use_skipped(self):
        busy = disk("vdc", children=[{"name": "vdc1", "mountpoints": ["/mnt"]}])
        got = autopart.pick_disk({"blockdevices": [disk("vda"), busy]})
        self.assertEqual(got["path"], "/dev/vda")


class Blank(unittest.TestCase):
    def test_blank_ok(self):
        autopart.check_blank(disk("vda"))

    def test_existing_table_refused(self):
        for kw in ({"pttype": "gpt"}, {"fstype": "vfat"}, {"children": [{"name": "vda1"}]}):
            with self.subTest(kw=kw), self.assertRaisesRegex(autopart.AutopartError, "not blank"):
                autopart.check_blank(disk("vda", **kw))

    def test_too_small_refused(self):
        with self.assertRaisesRegex(autopart.AutopartError, "smaller"):
            autopart.check_blank(disk("vda", size=10 * GiB))


class Layout(unittest.TestCase):
    def test_part_path(self):
        self.assertEqual(autopart.part_path("/dev/vda", 3), "/dev/vda3")
        self.assertEqual(autopart.part_path("/dev/nvme0n1", 1), "/dev/nvme0n1p1")

    def test_parted_layout_matches_partition_conf(self):
        argv = autopart.parted_argv("/dev/vda")
        self.assertIn("gpt", argv)
        self.assertEqual(argv[argv.index("EFI") + 2:argv.index("EFI") + 4], ["1MiB", "601MiB"])
        self.assertEqual(argv[argv.index("boot") + 2:argv.index("boot") + 4], ["601MiB", "2649MiB"])
        self.assertEqual(argv[-1], "100%")

    def test_mkfs_only_on_new_partitions(self):
        devs = [a[-1] for a in autopart.mkfs_argvs("/dev/vda", "/dev/mapper/luks-x")]
        self.assertEqual(devs, ["/dev/vda1", "/dev/vda2", "/dev/mapper/luks-x"])

    def test_partitions_gs_plain(self):
        ids = {f"/dev/vda{n}": {"uuid": f"U{n}", "partuuid": f"P{n}"} for n in (1, 2, 3)}
        gs = autopart.partitions_gs("/dev/vda", ids, None)
        self.assertEqual([p["mountPoint"] for p in gs], ["/boot/efi", "/boot", "/"])
        self.assertEqual(gs[0]["fs"], "fat32")
        self.assertNotIn("luksMapperName", gs[2])

    def test_partitions_gs_luks(self):
        ids = {f"/dev/vda{n}": {"uuid": f"U{n}", "partuuid": f"P{n}"} for n in (1, 2, 3)}
        ids["/dev/mapper/luks-L"] = {"uuid": "INNER", "partuuid": ""}
        root = autopart.partitions_gs("/dev/vda", ids, "L")[2]
        self.assertEqual((root["luksMapperName"], root["luksUuid"], root["uuid"]),
                         ("luks-L", "L", "INNER"))


if __name__ == "__main__":
    unittest.main()
