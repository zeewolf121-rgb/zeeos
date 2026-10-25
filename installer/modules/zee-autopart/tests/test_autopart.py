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


MiB = 1 << 20
ESP_T = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
MSR_T = "e3c9e316-0b5c-4db8-817d-f92df00215ae"
WIN_T = "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"


def part(n, start_mib, size, ptype, fstype):
    return {"name": f"vda{n}", "path": f"/dev/vda{n}", "type": "part", "partn": n,
            "start": start_mib * MiB // 512, "size": size, "parttype": ptype, "fstype": fstype,
            "mountpoints": [None]}


def windows_disk(win_fstype="ntfs", extra=()):
    # The install-test seed (vm/install-seed.py): ESP 512 MiB at 1 MiB, MSR 16 MiB, NTFS 20 GiB.
    kids = [part(1, 1, 512 * MiB, ESP_T, "vfat"), part(2, 513, 16 * MiB, MSR_T, None),
            part(3, 529, 20 * GiB, WIN_T, win_fstype), *extra]
    return disk("vda", pttype="gpt", children=kids)


class Alongside(unittest.TestCase):
    def test_seed_disk_shrinks_windows_just_enough(self):
        p = autopart.plan_alongside(windows_disk())
        # 40959 usable MiB - (529 + 20480) = 19950 free; 23552 needed -> shrink by 3602.
        self.assertEqual(p["ntfs_new_mib"], 20480 - 3602)
        self.assertEqual(p["boot_start"], 529 + p["ntfs_new_mib"])
        self.assertEqual(p["boot_end"] - p["boot_start"], 2048)
        self.assertEqual((p["esp"], p["esp_partn"], p["ntfs"], p["ntfs_partn"]),
                         ("/dev/vda1", 1, "/dev/vda3", 3))
        self.assertEqual((p["boot_partn"], p["root_partn"]), (4, 5))
        root_mib = 40959 - p["boot_end"]
        self.assertGreaterEqual(root_mib, autopart.ROOT_MIN_MIB)

    def test_no_shrink_when_space_is_free(self):
        d = windows_disk()
        d["size"] = 80 * GiB
        p = autopart.plan_alongside(d)
        self.assertIsNone(p["ntfs_new_mib"])
        self.assertEqual(p["boot_start"], 529 + 20480)
        self.assertFalse(any(a[0][0] in ("ntfsresize", "sfdisk")
                             for a in autopart.alongside_argvs("/dev/vda", p)))

    def test_refusals(self):
        cases = {
            "BitLocker": windows_disk("BitLocker"),
            "GPT": dict(windows_disk(), pttype="dos"),
            "not an NTFS": windows_disk(extra=[part(4, 21009, GiB, WIN_T, "ext4")]),
            "one FAT ESP": disk("vda", pttype="gpt", children=[
                part(1, 1, 512 * MiB, ESP_T, "vfat"), part(2, 513, 512 * MiB, ESP_T, "vfat"),
                part(3, 1025, 20 * GiB, WIN_T, "ntfs")]),
        }
        for why, d in cases.items():
            with self.subTest(why=why), self.assertRaisesRegex(autopart.AutopartError, why):
                autopart.plan_alongside(d)

    def test_esp_never_formatted_or_resized(self):
        p = autopart.plan_alongside(windows_disk())
        argvs = [a for a, _ in autopart.alongside_argvs("/dev/vda", p)]
        argvs += autopart.mkfs_argvs("/dev/vda", "/dev/vda5", p["boot_partn"], None)
        flat = [x for a in argvs for x in a]
        self.assertNotIn("/dev/vda1", flat)
        self.assertNotIn("mkfs.vfat", flat)
        self.assertNotIn("mklabel", flat)
        self.assertNotIn("--force", flat)
        self.assertNotIn("-f", [x for a in argvs if a[0] == "ntfsresize" for x in a])

    def test_resize_order_and_sizes(self):
        p = autopart.plan_alongside(windows_disk())
        steps = autopart.alongside_argvs("/dev/vda", p)
        self.assertEqual([a[0] for a, _ in steps], ["ntfsresize", "ntfsresize", "sfdisk", "parted"])
        self.assertIn("--no-action", steps[0][0])
        self.assertEqual(steps[1][0][-2:], [str(p["ntfs_new_mib"] * MiB), "/dev/vda3"])
        self.assertEqual(steps[2][0][-3:], ["-N", "3", "/dev/vda"])
        self.assertEqual(steps[2][1], f", {p['ntfs_new_mib']}MiB\n")
        self.assertIn("never", steps[2][0])

    def test_shrink_checked_against_ntfs_minimum(self):
        p = autopart.plan_alongside(windows_disk())
        autopart.check_shrink(p, "You might resize at 5000000000 bytes or 5000 MB")
        with self.assertRaisesRegex(autopart.AutopartError, "needs more space"):
            autopart.check_shrink(p, f"You might resize at {p['ntfs_new_mib'] * MiB} bytes")
        with self.assertRaisesRegex(autopart.AutopartError, "no minimum"):
            autopart.check_shrink(p, "")

    def test_partitions_gs_alongside_numbers(self):
        ids = {f"/dev/vda{n}": {"uuid": f"U{n}", "partuuid": f"P{n}"} for n in (1, 4, 5)}
        gs = autopart.partitions_gs("/dev/vda", ids, None, (1, 4, 5))
        self.assertEqual([p["device"] for p in gs], ["/dev/vda1", "/dev/vda4", "/dev/vda5"])


if __name__ == "__main__":
    unittest.main()
