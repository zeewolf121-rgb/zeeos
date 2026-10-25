# SPDX-License-Identifier: GPL-3.0-or-later
"""zee-preflight detection tests (P4-3 #4, P4-4 #5).

Run: python3 -m unittest discover -s installer/modules/zee-preflight/tests
Synthetic fixtures always run. The RealNtfs tests build real volumes with mkntfs + ntfscp
(ntfs-3g / ntfsprogs) exactly like vm/install-seed.py and skip when those tools are missing.
"""
import contextlib
import hashlib
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import preflight  # noqa: E402

META = 0x2000  # where the fixtures put the FVE metadata block
TPM, CLEAR = 0x0100, 0x0000
CLUSTER, MFT_LCN, REC = 4096, 4, 1024


def fve_block(protection):
    vmk = bytes(16) + bytes(8) + bytes(2) + struct.pack("<H", protection)
    entry = struct.pack("<4H", 8 + len(vmk), 0x0002, 0x0008, 1) + vmk
    header = struct.pack("<I", 48 + len(entry)).ljust(48, b"\0")
    return b"-FVE-FS-".ljust(64, b"\0") + header + entry


def image(path, oem, guid_at=None, meta_at=None, protection=TPM):
    data = bytearray(64 * 1024)
    data[0:3] = b"\xeb\x58\x90"
    data[3:11] = oem
    if guid_at is not None:
        data[guid_at:guid_at + 16] = preflight.BITLOCKER_GUID
    if meta_at is not None:
        struct.pack_into("<3Q", data, meta_at, META, 0, 0)
        block = fve_block(protection)
        data[META:META + len(block)] = block
    data[510:512] = b"\x55\xaa"
    path.write_bytes(bytes(data))
    return str(path)


def ntfs_image(path, flags=0):
    """Minimal NTFS: boot sector + MFT record 3 ($Volume) with fixups and $VOLUME_INFORMATION."""
    data = bytearray(MFT_LCN * CLUSTER + 8 * REC)
    data[0:3] = b"\xeb\x52\x90"
    data[3:11] = b"NTFS    "
    struct.pack_into("<HB", data, 11, 512, CLUSTER // 512)
    struct.pack_into("<Q", data, 48, MFT_LCN)
    struct.pack_into("<b", data, 64, -10)  # 2^10 = 1024-byte records
    data[510:512] = b"\x55\xaa"
    rec = bytearray(REC)
    rec[0:4] = b"FILE"
    struct.pack_into("<HH", rec, 4, 48, 3)  # update sequence at 48, USN + 2 entries
    struct.pack_into("<H", rec, 20, 56)  # first attribute
    vi = bytes(8) + bytes([3, 1]) + struct.pack("<H", flags)
    attr = struct.pack("<IIBBHHH", 0x70, 24 + 16, 0, 0, 0, 0, 0)  # type, len, resident
    attr += struct.pack("<IHBB", len(vi), 24, 0, 0) + vi + bytes(4)
    rec[56:56 + len(attr)] = attr
    struct.pack_into("<I", rec, 56 + len(attr), 0xFFFFFFFF)
    usn = b"\x07\x00"
    rec[48:50] = usn
    for i in (1, 2):  # save the real stride ends, then stamp the USN there
        end = i * 512
        rec[48 + 2 * i:50 + 2 * i] = rec[end - 2:end]
        rec[end - 2:end] = usn
    off = MFT_LCN * CLUSTER + preflight.MFT_VOLUME * REC
    data[off:off + REC] = rec
    path.write_bytes(bytes(data))
    return str(path)


class FakeTools(preflight.Reader):
    """Reader whose ntfsls/ntfscat answers come from a table: {volume: {name: content}}."""

    def __init__(self, volumes, fail=(), **kw):
        super().__init__(**kw)
        self.volumes, self.fail, self.calls = volumes, fail, []

    def tool(self, argv, limit=1 << 20):
        self.calls.append(argv)
        if self.dry_run:
            self.log.append("PLAN read-only " + " ".join(argv))
        name, dev = argv[0], argv[-1] if argv[0] == "ntfsls" else argv[1]
        if name in self.fail:
            return 1, b"", "Failed to mount: Input/output error"
        files = self.volumes.get(dev, {})
        if name == "ntfsls":
            return 0, "".join(f"{n}\n" for n in [".", "..", *files]).encode(), ""
        return 0, files[argv[2]][:limit], ""


def sha(paths):
    return {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        t = self.tmp
        self.fx = {
            "bitlocker": image(t / "bl.img", b"-FVE-FS-", 160, 176, TPM),
            "suspended": image(t / "bl-susp.img", b"-FVE-FS-", 160, 176, CLEAR),
            "togo": image(t / "togo.img", b"MSWIN4.1", 424, 440, TPM),
            "ntfs": ntfs_image(t / "ntfs.img"),
            "hibernated": ntfs_image(t / "hiber.img"),
            "resumed": ntfs_image(t / "wake.img"),
            "dirty": ntfs_image(t / "dirty.img", flags=preflight.VOLUME_IS_DIRTY),
            "exfat": image(t / "exfat.img", b"EXFAT   "),
        }
        self.volumes = {self.fx["hibernated"]: {"hiberfil.sys": b"HIBR" + bytes(8188)},
                        self.fx["resumed"]: {"hiberfil.sys": b"wake" + bytes(8188)},
                        self.fx["ntfs"]: {"thesis.txt": b"x"}}

    def reader(self, **kw):
        return FakeTools(self.volumes, **kw)


class Probe(Base):
    def test_kinds(self):
        want = {"bitlocker": preflight.BITLOCKER, "suspended": preflight.SUSPENDED,
                "togo": preflight.BITLOCKER, "ntfs": "ntfs", "hibernated": preflight.HIBERNATED,
                "resumed": "ntfs", "dirty": preflight.DIRTY, "exfat": "exfat"}
        for name, kind in want.items():
            with self.subTest(name):
                self.assertEqual(preflight.probe(self.fx[name], self.reader(dry_run=True)), kind)

    def test_mswin_without_guid_is_not_bitlocker(self):
        fat = image(self.tmp / "fat.img", b"MSWIN4.1")
        self.assertEqual(preflight.probe(fat, self.reader()), "other")

    def test_hiberfil_name_is_case_insensitive(self):
        self.volumes[self.fx["ntfs"]] = {"HIBERFIL.SYS": b"hibr" + bytes(12)}
        self.assertEqual(preflight.probe(self.fx["ntfs"], self.reader()), preflight.HIBERNATED)

    def test_dirty_is_checked_without_any_tool(self):
        r = self.reader()
        self.assertEqual(preflight.probe(self.fx["dirty"], r), preflight.DIRTY)
        self.assertEqual(r.calls, [])

    def test_torn_mft_record_fails_closed(self):
        p = Path(self.fx["ntfs"])
        data = bytearray(p.read_bytes())
        data[MFT_LCN * CLUSTER + 3 * REC + 510] ^= 0xFF  # break the USN at the first stride end
        p.write_bytes(bytes(data))
        found, blocks, why = preflight.scan([str(p)], self.reader())
        self.assertEqual(found[str(p)], preflight.UNREADABLE)
        self.assertIn("update sequence", why[str(p)])

    def test_tool_failure_fails_closed(self):
        found, _, why = preflight.scan([self.fx["ntfs"]], self.reader(fail=("ntfsls",)))
        self.assertEqual(found[self.fx["ntfs"]], preflight.UNREADABLE)
        self.assertIn("ntfsls failed", why[self.fx["ntfs"]])

    def test_missing_tool_fails_closed(self):
        r = preflight.Reader()
        old = os.environ.get("PATH")
        os.environ["PATH"] = str(self.tmp)  # no ntfsls here
        try:
            found, _, _ = preflight.scan([self.fx["ntfs"]], r)
        finally:
            os.environ["PATH"] = old
        self.assertEqual(found[self.fx["ntfs"]], preflight.UNREADABLE)

    def test_unreadable_device_fails_closed(self):
        missing = str(self.tmp / "missing")
        found, blocks, _ = preflight.scan([missing], self.reader())
        self.assertEqual(found, {missing: preflight.UNREADABLE})
        self.assertEqual(len(blocks), 1)


class Scan(Base):
    def test_every_device_scanned_and_blocking_ones_explained(self):
        found, blocks, _ = preflight.scan(list(self.fx.values()), self.reader(dry_run=True))
        self.assertEqual(set(found), set(self.fx.values()))
        self.assertEqual(len(blocks), 5)  # bitlocker, suspended, To Go, hibernated, dirty
        text = "".join(blocks)
        self.assertIn("recovery key", text)
        self.assertIn("Turn off Fast Startup", text)
        self.assertIn("chkdsk /f", text)


DEVICES = preflight.lsblk_devices({"blockdevices": [
    {"path": "/dev/vda", "type": "disk", "pkname": None, "serial": None},
    {"path": "/dev/vda1", "type": "part", "pkname": "/dev/vda", "serial": None},
    {"path": "/dev/vda3", "type": "part", "pkname": "/dev/vda", "serial": None},
    {"path": "/dev/vdb", "type": "disk", "pkname": None, "serial": "ZEEOS-AUTOINSTALL"},
    {"path": "/dev/sdb", "type": "disk", "pkname": None, "serial": "USB1"},
    {"path": "/dev/sdb1", "type": "part", "pkname": "/dev/sdb", "serial": None},
    {"path": "/dev/sr0", "type": "rom", "pkname": None, "serial": None},
]})


class Touched(unittest.TestCase):
    def test_lsblk_devices(self):
        self.assertEqual([d["path"] for d in DEVICES],
                         ["/dev/vda", "/dev/vda1", "/dev/vda3", "/dev/vdb", "/dev/sdb", "/dev/sdb1"])
        self.assertEqual(DEVICES[2]["disk"], "/dev/vda")
        self.assertEqual(DEVICES[3]["serial"], "ZEEOS-AUTOINSTALL")

    def test_untouched_disk_is_ignored(self):
        found = {"/dev/vda": "other", "/dev/vda1": "other", "/dev/vda3": "ntfs",
                 "/dev/vdb": "other", "/dev/sdb": "other", "/dev/sdb1": preflight.BITLOCKER}
        paths = preflight.touched(DEVICES, found, ["/dev/vda4", "/dev/vda5", "/dev/vda1"])
        self.assertEqual(paths, ["/dev/vda", "/dev/vda1", "/dev/vda3"])
        self.assertIsNone(preflight.refusal(found, {}, paths))

    def test_volume_on_the_planned_disk_is_refused(self):
        found = {"/dev/vda": "other", "/dev/vda1": "other", "/dev/vda3": preflight.HIBERNATED}
        paths = preflight.touched(DEVICES, found, ["/dev/vda4"])
        reason, steps = preflight.refusal(found, {}, paths)
        self.assertEqual(reason, "refusing to resize or install: /dev/vda3 is ntfs-hibernated")
        self.assertIn("shutdown /s /t 0", steps)

    def test_no_plan_counts_every_disk_but_the_preset(self):
        found = {d["path"]: "other" for d in DEVICES}
        found["/dev/vdb"] = preflight.UNREADABLE
        paths = preflight.touched(DEVICES, found, [])
        self.assertNotIn("/dev/vdb", paths)
        self.assertIn("/dev/sdb1", paths)
        self.assertIsNone(preflight.refusal(found, {"/dev/vdb": "x"}, paths))

    def test_unmappable_plan_counts_every_disk(self):
        found = {"/dev/vda3": "ntfs", "/dev/sdb1": preflight.BITLOCKER}
        paths = preflight.touched(DEVICES, found, ["/dev/vda4", "New partition"])
        self.assertIn("/dev/sdb1", paths)

    def test_parent_disk(self):
        for part, disk in (("/dev/sda4", "/dev/sda"), ("/dev/vda12", "/dev/vda"),
                           ("/dev/nvme0n1p3", "/dev/nvme0n1"), ("/dev/mmcblk0p2", "/dev/mmcblk0"),
                           ("/dev/vda", "/dev/vda")):
            self.assertEqual(preflight.parent_disk(part), disk)

    def test_unreadable_touched_device_is_refused(self):
        found = {"/dev/vda3": preflight.UNREADABLE}
        reason, _ = preflight.refusal(found, {"/dev/vda3": "ntfsls failed: rc=1"},
                                      preflight.touched(DEVICES, found, []))
        self.assertEqual(reason, "refusing to resize or install: /dev/vda3 is unreadable "
                                 "(ntfsls failed: rc=1)")


class Cli(Base):
    def run_main(self, args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = preflight.main(args)
        return rc, out.getvalue(), err.getvalue()

    def test_dry_run_logs_every_read_and_writes_nothing(self):
        paths = [self.fx[k] for k in ("bitlocker", "suspended", "togo", "dirty", "exfat")]
        before = sha(paths)
        rc, out, err = self.run_main(["--dry-run"] + [a for p in paths for a in ("--device", p)])
        self.assertEqual(rc, 2)
        self.assertIs(json.loads(out)["resize_blocked"], True)
        self.assertIn(f"PLAN probe {len(paths)} device(s)", err)
        for p in paths:
            self.assertIn(f"PLAN read-only {p} offset=0 length=512", err)
        self.assertIn(f"PLAN read-only {self.fx['bitlocker']} offset={META}", err)
        self.assertIn(f"PLAN read-only {self.fx['dirty']} offset={MFT_LCN * CLUSTER + 3 * REC} "
                      f"length={REC}", err)
        self.assertEqual(before, sha(paths))

    def test_dry_run_logs_tool_calls(self):
        r = self.reader(dry_run=True)
        preflight.scan([self.fx["hibernated"]], r)
        self.assertIn(f"PLAN read-only ntfsls -a {self.fx['hibernated']}", r.log)
        self.assertIn(f"PLAN read-only ntfscat {self.fx['hibernated']} hiberfil.sys", r.log)

    def test_clean_disks_pass(self):
        rc, out, _ = self.run_main(["--device", self.fx["exfat"], "--device", self.fx["togo"]])
        self.assertEqual(rc, 2)
        rc, out, _ = self.run_main(["--device", self.fx["exfat"]])
        self.assertEqual(rc, 0)


NTFS_TOOLS = ("mkntfs", "ntfscp", "ntfsls", "ntfscat")


@unittest.skipUnless(all(shutil.which(t) for t in NTFS_TOOLS),
                     "needs mkntfs, ntfscp, ntfsls, ntfscat (ntfs-3g, ntfsprogs)")
class RealNtfs(unittest.TestCase):
    """Real volumes built the way vm/install-seed.py builds case (b) and refuse-hibernated."""

    def volume(self, name, files):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        img = tmp / f"{name}.img"
        with img.open("wb") as f:
            f.truncate(64 << 20)
        subprocess.run(["mkntfs", "--fast", "--force", "--quiet", "--label", "Windows", str(img)],
                       check=True, capture_output=True)
        for rel, data in files.items():
            src = tmp / rel
            src.write_bytes(data)
            subprocess.run(["ntfscp", "--force", str(img), str(src), rel], check=True,
                           capture_output=True)
        return str(img)

    def probe(self, img):
        before = sha([img])
        kind = preflight.probe(img, preflight.Reader(dry_run=True))
        self.assertEqual(before, sha([img]), "the probe changed the volume")
        return kind

    def test_clean_volume_with_data_is_ok(self):
        self.assertEqual(self.probe(self.volume("clean", {"thesis.txt": b"Do not lose this.\n"})),
                         "ntfs")

    def test_seed_hiberfil_is_refused(self):
        hiberfil = b"hibr" + bytes(4092) + b"\x01" * 4096  # vm/install-seed.py HIBERFIL
        img = self.volume("hiber", {"thesis.txt": b"x" * 4096, "hiberfil.sys": hiberfil})
        self.assertEqual(self.probe(img), preflight.HIBERNATED)

    def test_resumed_hiberfil_is_ok(self):
        img = self.volume("wake", {"hiberfil.sys": b"wake" + bytes(8188)})
        self.assertEqual(self.probe(img), "ntfs")

    def test_dirty_flag_is_refused(self):
        img = self.volume("dirty", {"thesis.txt": b"x"})
        reader = preflight.Reader()
        with open(img, "rb") as f:
            head = f.read(512)
        _, mft, size = preflight.ntfs_geometry(head)
        off = mft + preflight.MFT_VOLUME * size
        with open(img, "rb") as f:
            f.seek(off)
            raw = f.read(size)
        at = preflight.volume_info_offset(preflight.apply_fixups(raw))
        self.assertNotIn(at % 512, (510, 511), "flags sit under a fixup; patch the USA instead")
        self.assertEqual(preflight.ntfs_volume_flags(img, reader, head) & 1, 0)
        with open(img, "r+b") as f:
            f.seek(off + at)
            f.write(struct.pack("<H", struct.unpack_from("<H", raw, at)[0] | 1))
        self.assertEqual(self.probe(img), preflight.DIRTY)


if __name__ == "__main__":
    unittest.main()
