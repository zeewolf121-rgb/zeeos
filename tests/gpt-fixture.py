#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tiny GPT seed disks for tests/install-selftest.sh (stdlib only, written independently of
vm/install-checksums.py's parser so the two check each other).

  gpt-fixture.py make DIR        -> DIR/disk.img (4 MiB: ESP, MSR, Windows) + DIR/seed.json
  gpt-fixture.py mutate DISK OP  -> what an installer might do to it; OP is one of:
      shrink          Windows ends earlier and a ZeeOS partition fills the gap (allowed)
      delete-msr      MSR entry removed            type-esp      ESP retyped as basic data
      move-esp        ESP starts 8 sectors earlier grow-windows  Windows ends later
      corrupt-backup  backup header byte flipped   mismatch      primary rewritten, backup stale
      truncate        last MiB cut off (backup GPT gone)
"""
import json
import os
import struct
import sys
import uuid
import zlib

SECTOR = 512
SIZE = 4 << 20
LBAS = SIZE // SECTOR
DISK_GUID = "5EED0000-0000-4000-8000-000000000001"
ESP_T, MSR_T = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "E3C9E316-0B5C-4DB8-817D-F92DF00215AE"
BASIC_T, LINUX_T = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
PARTS = [
    {"name": "esp", "type": ESP_T, "guid": "5EED0000-0000-4000-8000-0000000000E5", "first": 2048, "last": 2559},
    {"name": "msr", "type": MSR_T, "guid": "5EED0000-0000-4000-8000-00000000005E", "first": 2560, "last": 2623},
    {"name": "windows", "type": BASIC_T, "guid": "5EED0000-0000-4000-8000-000000000003", "first": 4096, "last": 6143},
]


def entries(parts):
    out = bytearray(128 * 128)
    for i, p in enumerate(parts):
        e = (uuid.UUID(p["type"]).bytes_le + uuid.UUID(p["guid"]).bytes_le
             + struct.pack("<3Q", p["first"], p["last"], 0) + p["name"].encode("utf-16-le").ljust(72, b"\0"))
        out[i * 128:(i + 1) * 128] = e
    return bytes(out)


def header(my, alt, entries_lba, ecrc):
    h = bytearray(struct.pack("<8sIII4xQQQQ16sQIII", b"EFI PART", 0x10000, 92, 0, my, alt, 34, LBAS - 34,
                              uuid.UUID(DISK_GUID).bytes_le, entries_lba, 128, 128, ecrc))
    struct.pack_into("<I", h, 16, zlib.crc32(h))
    return bytes(h).ljust(SECTOR, b"\0")


def write_gpt(disk, parts, primary=True, backup=True):
    e = entries(parts)
    ecrc = zlib.crc32(e)
    with open(disk, "r+b") as f:
        if primary:
            f.seek(SECTOR)
            f.write(header(1, LBAS - 1, 2, ecrc) + e)
        if backup:
            f.seek((LBAS - 33) * SECTOR)
            f.write(e + header(LBAS - 1, 1, LBAS - 33, ecrc))


def make(d):
    os.makedirs(d, exist_ok=True)
    disk = os.path.join(d, "disk.img")
    with open(disk, "wb") as f:
        f.truncate(SIZE)
        mbr = bytearray(SECTOR)
        mbr[446:462] = struct.pack("<BBBBBBBBII", 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, LBAS - 1)
        mbr[510:512] = b"\x55\xaa"
        f.write(mbr)
        for p in PARTS:  # known, non-zero bytes in every partition
            f.seek(p["first"] * SECTOR)
            f.write((bytes(range(1, 256)) * 8192)[:(p["last"] - p["first"] + 1) * SECTOR])
    write_gpt(disk, PARTS)
    seed = {"case": "t", "size": SIZE, "files": {},
            "partitions": [{"name": p["name"], "offset": p["first"] * SECTOR,
                            "size": (p["last"] - p["first"] + 1) * SECTOR} for p in PARTS],
            "gpt": {"disk_guid": DISK_GUID, "partitions": PARTS, "shrink": ["windows"]}}
    with open(os.path.join(d, "seed.json"), "w") as f:
        json.dump(seed, f, indent=1)


def with_part(name, **change):
    return [dict(p, **change) if p["name"] == name else dict(p) for p in PARTS]


def mutate(disk, op):
    shrunk = with_part("windows", last=5119) + [
        {"name": "zeeos", "type": LINUX_T, "guid": "5EED0000-0000-4000-8000-00000000002E", "first": 5120, "last": LBAS - 34}]
    if op == "shrink":
        write_gpt(disk, shrunk)
    elif op == "delete-msr":
        write_gpt(disk, [p for p in PARTS if p["name"] != "msr"])
    elif op == "type-esp":
        write_gpt(disk, with_part("esp", type=BASIC_T))
    elif op == "move-esp":
        write_gpt(disk, with_part("esp", first=2040, last=2551))
    elif op == "grow-windows":
        write_gpt(disk, with_part("windows", last=6200))
    elif op == "mismatch":
        write_gpt(disk, shrunk, backup=False)
    elif op == "corrupt-backup":
        with open(disk, "r+b") as f:
            f.seek((LBAS - 1) * SECTOR + 60)  # inside the disk GUID, which the header CRC covers
            b = f.read(1)
            f.seek(-1, os.SEEK_CUR)
            f.write(bytes([b[0] ^ 0xFF]))
    elif op == "truncate":
        os.truncate(disk, SIZE - (1 << 20))
    else:
        sys.exit(f"gpt-fixture: unknown op {op}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "make":
        make(a[1])
    elif len(a) == 3 and a[0] == "mutate":
        mutate(a[1], a[2])
    else:
        sys.exit(__doc__)
