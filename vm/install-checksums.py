#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checksums of an install-test disk's pre-existing data, taken outside the guest (P4-8).

  install-checksums.py DISK SEED_JSON partitions   -> {"<name>": "<sha256>"} for each seed partition, plus the
                                                      primary and backup GPT areas and the disk size
  install-checksums.py DISK SEED_JSON files        -> {"esp:<path>": "<sha256>", "ntfs:<path>": ...}
  install-checksums.py DISK SEED_JSON manifest     -> the file hashes seed.json recorded when the disk was built
  install-checksums.py compare BEFORE AFTER        -> exit 1 and list every key that changed, vanished, or is "missing"

Tier 1 (partitions, stdlib only) hashes whole partition ranges: right for the refuse cases, where
nothing may change at all. Tier 2 (files) reads individual files out of the image, because an
alongside install legitimately shrinks the Windows volume and adds ZeeOS's files to the ESP; it
needs mcopy (mtools) and ntfscat (ntfs-3g). Nothing here writes to DISK.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

MiB = 1 << 20


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
    parts = {p["name"]: p for p in seed["partitions"]}
    for kind, tool in (("esp", "mcopy"), ("ntfs", "ntfscat")):
        entries = seed["files"].get(kind, [])
        if not entries:
            continue
        if shutil.which(tool) is None:
            sys.exit(f"install-checksums: needs {tool} for the {kind} file checks")
        p = parts["esp" if kind == "esp" else "windows"]
        for e in entries:
            if kind == "esp":
                cmd = ["mcopy", "-n", "-i", f"{disk}@@{p['offset']}", f"::/{e['path']}", "-"]
                r = subprocess.run(cmd, capture_output=True)
            else:
                with tempfile.TemporaryDirectory() as td:
                    img = os.path.join(td, "win.img")
                    extract(disk, p["offset"], p["size"], img)
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
    if len(argv) != 3 or argv[2] not in ("partitions", "files", "manifest"):
        sys.exit(__doc__)
    disk, seed = argv[0], json.load(open(argv[1]))
    result = {"partitions": partitions, "files": files}.get(argv[2], lambda d, s: manifest(s))(disk, seed)
    print(json.dumps(result, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
