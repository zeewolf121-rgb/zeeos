#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checksums of an install-test disk's pre-existing data, taken outside the guest (P4-8).

  install-checksums.py DISK SEED_JSON partitions   -> {"<name>": "<sha256>"} for each seed partition, plus the
                                                      primary and backup GPT areas and the disk size
  install-checksums.py DISK SEED_JSON files        -> {"esp:<path>": "<sha256>", "ntfs:<path>": ...}
  install-checksums.py DISK SEED_JSON manifest     -> the file hashes seed.json recorded when the disk was built
  install-checksums.py DISK SEED_JSON layout       -> exit 1 and list every problem with the disk's actual GPT
  install-checksums.py compare BEFORE AFTER        -> exit 1 and list every key that changed, vanished, or is "missing"

Tier 1 (partitions, stdlib only) hashes whole partition ranges: right for the refuse cases, where
nothing may change at all. Tier 2 (files) reads individual files out of the image, because an
alongside install legitimately shrinks the Windows volume and adds ZeeOS's files to the ESP; it
needs mcopy (mtools) and ntfscat (ntfs-3g). Files are read from the ranges in the disk's actual
GPT, never from the seed's offsets, and the harness runs them only after "layout" (stdlib only)
has accepted that GPT: both copies valid and identical, the disk not truncated, and every seed
partition still there with the same type, unique GUID and start. Only the partitions seed.json
lists under gpt.shrink may end earlier. Nothing here writes to DISK.
"""
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib

MiB = 1 << 20
SECTOR = 512


class GptError(Exception):
    pass


def guid(raw):
    return str(uuid.UUID(bytes_le=bytes(raw))).upper()


def gpt_copy(f, lba):
    """Parse and CRC-check the GPT header at lba and its entry array."""
    which = "primary" if lba == 1 else "backup"
    f.seek(lba * SECTOR)
    hdr = f.read(SECTOR)
    if len(hdr) < SECTOR or hdr[:8] != b"EFI PART":
        raise GptError(f"{which} GPT header missing at LBA {lba}")
    hsize, hcrc = struct.unpack_from("<II", hdr, 12)
    if not 92 <= hsize <= SECTOR:
        raise GptError(f"{which} GPT header size {hsize} invalid")
    h = bytearray(hdr[:hsize])
    h[16:20] = bytes(4)
    if zlib.crc32(h) != hcrc:
        raise GptError(f"{which} GPT header CRC mismatch")
    my_lba, alt_lba, first_usable, last_usable = struct.unpack_from("<4Q", hdr, 24)
    entries_lba, n, esize, ecrc = struct.unpack_from("<QIII", hdr, 72)
    if my_lba != lba:
        raise GptError(f"{which} GPT header says it is at LBA {my_lba}, found at {lba}")
    if esize < 128 or esize % 8 or n * esize > 4 * MiB:
        raise GptError(f"{which} GPT entry array {n}x{esize} invalid")
    f.seek(entries_lba * SECTOR)
    raw = f.read(n * esize)
    if len(raw) != n * esize or zlib.crc32(raw) != ecrc:
        raise GptError(f"{which} GPT entry array CRC mismatch or truncated")
    parts = []
    for i in range(n):
        e = raw[i * esize:(i + 1) * esize]
        if e[:16] == bytes(16):
            continue
        first, last = struct.unpack_from("<2Q", e, 32)
        parts.append({"index": i + 1, "type": guid(e[:16]), "guid": guid(e[16:32]), "first": first, "last": last})
    return {"alt": alt_lba, "first_usable": first_usable, "last_usable": last_usable,
            "disk_guid": guid(hdr[56:72]), "parts": parts}


def read_gpt(disk):
    """Both GPT copies, checked against each other and the disk size; returns the primary."""
    size = os.path.getsize(disk)
    if size % SECTOR or size < 68 * SECTOR:
        raise GptError(f"disk size {size} cannot hold a GPT")
    last = size // SECTOR - 1
    with open(disk, "rb") as f:
        primary = gpt_copy(f, 1)
        if primary["alt"] != last:
            raise GptError(f"primary GPT puts the backup at LBA {primary['alt']} but the disk ends at {last}")
        backup = gpt_copy(f, last)
    if backup["alt"] != 1:
        raise GptError("backup GPT does not point back at LBA 1")
    for k in ("disk_guid", "first_usable", "last_usable", "parts"):
        if primary[k] != backup[k]:
            raise GptError(f"primary and backup GPT differ in {k}")
    if not 2 <= primary["first_usable"] <= primary["last_usable"] < last:
        raise GptError("GPT usable range invalid")
    spans = sorted((p["first"], p["last"], p["index"]) for p in primary["parts"])
    for first, end, i in spans:
        if not primary["first_usable"] <= first <= end <= primary["last_usable"]:
            raise GptError(f"partition {i} (LBA {first}-{end}) lies outside the usable range")
    for (_, end, i), (first, _, j) in zip(spans, spans[1:]):
        if first <= end:
            raise GptError(f"partitions {i} and {j} overlap")
    return primary


def layout(disk, seed):
    """Every problem with disk's actual GPT against the seed's; an empty list accepts the layout."""
    want = seed.get("gpt")
    if not want:
        return ["seed.json records no GPT, so the layout cannot be validated"]
    errors = []
    size = os.path.getsize(disk)
    if size != seed["size"]:
        errors.append(f"disk size {size}, seed was {seed['size']} (truncated or resized)")
    try:
        got = read_gpt(disk)
    except GptError as e:
        return errors + [f"invalid GPT: {e}"]
    if got["disk_guid"] != want["disk_guid"]:
        errors.append(f"disk GUID changed: {want['disk_guid']} -> {got['disk_guid']}")
    by_guid = {p["guid"]: p for p in got["parts"]}
    for w in want["partitions"]:
        n, g = w["name"], by_guid.get(w["guid"])
        if g is None:
            errors.append(f"{n}: deleted (no partition with GUID {w['guid']})")
            continue
        if g["type"] != w["type"]:
            errors.append(f"{n}: type changed {w['type']} -> {g['type']}")
        if g["first"] != w["first"]:
            errors.append(f"{n}: moved, starts at LBA {g['first']}, was {w['first']}")
        if n in want.get("shrink", []):
            if g["last"] > w["last"]:
                errors.append(f"{n}: grew, ends at LBA {g['last']}, was {w['last']}")
        elif g["last"] != w["last"]:
            errors.append(f"{n}: resized, ends at LBA {g['last']}, was {w['last']}")
    return errors


def ranges(disk, seed):
    """{name: (offset, size)} of the seed partitions as the disk's GPT has them now."""
    if not seed.get("gpt"):
        return {p["name"]: (p["offset"], p["size"]) for p in seed["partitions"]}
    try:
        by_guid = {p["guid"]: p for p in read_gpt(disk)["parts"]}
    except GptError:
        return {}
    return {w["name"]: (g["first"] * SECTOR, (g["last"] - g["first"] + 1) * SECTOR)
            for w in seed["gpt"]["partitions"] if (g := by_guid.get(w["guid"]))}


def part_sha(disk, offset, size):
    h = hashlib.sha256()
    with open(disk, "rb") as f:
        f.seek(offset)
        left = size
        while left:
            chunk = f.read(min(left, 4 * MiB))
            if not chunk:
                break
            h.update(chunk)
            left -= len(chunk)
    return h.hexdigest()


def partitions(disk, seed):
    out = {p["name"]: part_sha(disk, p["offset"], p["size"]) for p in seed["partitions"]}
    # An installer that refuses must not touch the partition tables either (protective MBR + primary
    # GPT live in the first MiB, the backup GPT in the last MiB; seed partitions start at 1 MiB).
    size = os.path.getsize(disk)
    out["disk-size"] = str(size)
    out["gpt-primary"] = part_sha(disk, 0, min(MiB, size))
    out["gpt-backup"] = part_sha(disk, max(0, size - MiB), min(MiB, size))
    return out


def manifest(seed):
    return {f"{kind}:{e['path']}": e["sha256"] for kind, entries in seed["files"].items() for e in entries}


def extract(disk, offset, size, dest):
    """Copy one partition range to dest, keeping holes sparse."""
    with open(disk, "rb") as src, open(dest, "wb") as dst:
        src.seek(offset)
        left = size
        while left:
            chunk = src.read(min(left, 4 * MiB))
            if not chunk:
                break
            if chunk.count(0) == len(chunk):
                dst.seek(len(chunk), os.SEEK_CUR)
            else:
                dst.write(chunk)
            left -= len(chunk)
        dst.truncate(size)


def files(disk, seed):
    out = {}
    parts = ranges(disk, seed)
    for kind, tool in (("esp", "mcopy"), ("ntfs", "ntfscat")):
        entries = seed["files"].get(kind, [])
        if not entries:
            continue
        if shutil.which(tool) is None:
            sys.exit(f"install-checksums: needs {tool} for the {kind} file checks")
        p = parts.get("esp" if kind == "esp" else "windows")
        for e in entries:
            if p is None:  # partition gone or GPT unreadable: there is nothing to read
                r = subprocess.CompletedProcess([], 1, b"")
            elif kind == "esp":
                cmd = ["mcopy", "-n", "-i", f"{disk}@@{p[0]}", f"::/{e['path']}", "-"]
                r = subprocess.run(cmd, capture_output=True)
            else:
                with tempfile.TemporaryDirectory() as td:
                    img = os.path.join(td, "win.img")
                    extract(disk, p[0], p[1], img)
                    r = subprocess.run(["ntfscat", img, e["path"]], capture_output=True)
            out[f"{kind}:{e['path']}"] = hashlib.sha256(r.stdout).hexdigest() if r.returncode == 0 else "missing"
    return out


def compare(before, after):
    # An unreadable file proves nothing, even if it is unreadable both times.
    bad = [k for k in before if before[k] == "missing" or after.get(k) != before[k]]
    for k in bad:
        print(f"changed: {k} {before[k][:12]} -> {after.get(k, 'missing')[:12]}")
    return 1 if bad else 0


def main(argv):
    if len(argv) == 3 and argv[0] == "compare":
        with open(argv[1]) as b, open(argv[2]) as a:
            return compare(json.load(b), json.load(a))
    if len(argv) != 3 or argv[2] not in ("partitions", "files", "manifest", "layout"):
        sys.exit(__doc__)
    disk, seed = argv[0], json.load(open(argv[1]))
    if argv[2] == "layout":
        errors = layout(disk, seed)
        for e in errors:
            print(e)
        return 1 if errors else 0
    result = {"partitions": partitions, "files": files}.get(argv[2], lambda d, s: manifest(s))(disk, seed)
    print(json.dumps(result, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
