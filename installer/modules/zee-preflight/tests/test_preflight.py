# SPDX-License-Identifier: GPL-3.0-or-later
"""Signature detection on synthetic fixture images. Run: pytest installer/modules/zee-preflight/tests"""
import hashlib
import json
import struct
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import preflight  # noqa: E402

META = 0x2000  # where the fixtures put the FVE metadata block
TPM, CLEAR = 0x0100, 0x0000


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


@pytest.fixture
def fixtures(tmp_path):
    return {
        "bitlocker": image(tmp_path / "bl.img", b"-FVE-FS-", 160, 176, TPM),
        "suspended": image(tmp_path / "bl-susp.img", b"-FVE-FS-", 160, 176, CLEAR),
        "togo": image(tmp_path / "togo.img", b"MSWIN4.1", 424, 440, TPM),
        "ntfs": image(tmp_path / "ntfs.img", b"NTFS    "),
        "exfat": image(tmp_path / "exfat.img", b"EXFAT   "),
    }


@pytest.mark.parametrize("name,kind", [
    ("bitlocker", preflight.BITLOCKER),
    ("suspended", preflight.SUSPENDED),
    ("togo", preflight.BITLOCKER),
    ("ntfs", "ntfs"),
    ("exfat", "exfat"),
])
def test_probe(fixtures, name, kind):
    assert preflight.probe(fixtures[name], preflight.Reader(dry_run=True)) == kind


def test_mswin_without_guid_is_not_bitlocker(tmp_path):
    fat = image(tmp_path / "fat.img", b"MSWIN4.1")
    assert preflight.probe(fat, preflight.Reader()) == "other"


def test_scan_covers_every_device_and_blocks(fixtures):
    reader = preflight.Reader(dry_run=True)
    found, blocks = preflight.scan(list(fixtures.values()), reader)
    assert set(found) == set(fixtures.values())
    assert len(blocks) == 3  # bitlocker, suspended, To Go
    assert all("recovery key" in b and "Suspend" in b for b in blocks)


def test_unreadable_fails_closed(tmp_path):
    found, blocks = preflight.scan([str(tmp_path / "missing")], preflight.Reader())
    assert found == {str(tmp_path / "missing"): preflight.UNREADABLE}
    assert len(blocks) == 1


def test_dry_run_logs_every_read_and_writes_nothing(fixtures, capsys):
    before = {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in fixtures.values()}
    rc = preflight.main(["--dry-run"] + [a for p in fixtures.values() for a in ("--device", p)])
    out, err = capsys.readouterr()
    assert rc == 2
    assert json.loads(out)["resize_blocked"] is True
    assert "PLAN probe 5 device(s)" in err
    for p in fixtures.values():
        assert f"PLAN read-only {p} offset=0 length=512" in err
    assert f"PLAN read-only {fixtures['bitlocker']} offset={META}" in err
    assert before == {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in fixtures.values()}


def test_clean_disks_pass(fixtures):
    rc = preflight.main(["--device", fixtures["ntfs"], "--device", fixtures["exfat"]])
    assert rc == 0
