#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the install-test seed disk for one case (docs/phases/phase-4.md, P4-8).

  install-seed.py CASE OUTDIR      CASE: erase | luks | alongside | refuse-bitlocker | refuse-hibernated

Writes OUTDIR/disk.img (sparse raw, 40 GiB) and OUTDIR/seed.json. Everything is built from image
files: nothing is mounted, and the target must be a regular file (never a block device).

seed.json lists the pre-existing partitions (offset, size) and, for alongside, the pre-existing ESP
and NTFS files with SHA-256, so install-checksums.py can prove the install left them alone.

Tools: erase/luks need none. The partitioned cases need sgdisk (gdisk), mkfs.fat + mcopy (dosfstools,
mtools) and mkntfs + ntfscp (ntfs-3g); a missing tool is reported by name.
"""
import hashlib
import json
import os
import shutil
import stat
import struct
import subprocess
import sys
from pathlib import Path

MiB = 1 << 20
DISK = 40 << 30
ESP = (1 * MiB, 512 * MiB)  # (offset, size): GPT partition 1
MSR = (513 * MiB, 16 * MiB)  # partition 2, Microsoft reserved (empty)
WIN = (529 * MiB, 20 << 30)  # partition 3, the "Windows" volume
CASES = ("erase", "luks", "alongside", "refuse-bitlocker", "refuse-hibernated")
GUID_ESP = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
GUID_MSR = "E3C9E316-0B5C-4DB8-817D-F92DF00215AE"
GUID_BASIC = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

# Same on-disk layout as installer/modules/zee-preflight's fixtures (#4): OEM id at 3, BitLocker
# GUID at 160, FVE metadata offsets at 176, a v2 metadata block whose VMK is TPM-protected.
BITLOCKER_GUID = bytes.fromhex("3bd66749292ed84a8399f6a339e3d001")
FVE_META = 0x2000


def die(msg, code=2):
    print(f"install-seed: {msg}", file=sys.stderr)
    sys.exit(code)


def need(*tools):
    missing = [t for t in tools if shutil.which(t) is None]
    if missing:
        die(f"needs {', '.join(missing)} on PATH (gdisk, dosfstools, mtools, ntfs-3g)")


def run(*cmd):
    print("+ " + " ".join(cmd), file=sys.stderr)
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def new_disk(path):
    """Create the sparse disk. Never follows a symlink: a reused OUT must not redirect the write."""
    if path.is_symlink() or (path.exists() and not stat.S_ISREG(path.lstat().st_mode)):
        die(f"{path} exists and is not a regular file; refusing to write")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "wb") as f:
        f.truncate(DISK)


def splice(disk, part_img, offset):
    """Copy a partition image into the disk at offset (sparse-friendly, never past its end)."""
    with part_img.open("rb") as src, disk.open("r+b") as dst:
        dst.seek(offset)
        while chunk := src.read(4 * MiB):
            if chunk.count(0) == len(chunk):
                dst.seek(len(chunk), os.SEEK_CUR)
            else:
                dst.write(chunk)


def gpt(disk):
    run("sgdisk", "--zap-all", str(disk))
    for n, ((off, size), guid, name) in enumerate(
        [(ESP, GUID_ESP, "EFI system partition"), (MSR, GUID_MSR, "Microsoft reserved partition"),
         (WIN, GUID_BASIC, "Basic data partition")], start=1):
        run("sgdisk", f"--new={n}:{off // 512}:{(off + size) // 512 - 1}", f"--typecode={n}:{guid}",
            f"--change-name={n}:{name}", str(disk))


def esp_image(work):
    img = work / "esp.img"
    img.unlink(missing_ok=True)
    run("mkfs.fat", "-F", "32", "-n", "SYSTEM", "-C", str(img), str(ESP[1] // 1024))
    files = {
        "EFI/Microsoft/Boot/bootmgfw.efi": b"MZ install-test stand-in for Windows Boot Manager\n" * 64,
        "EFI/Microsoft/Boot/BCD": hashlib.sha512(b"bcd").digest() * 128,
        "EFI/Boot/bootx64.efi": b"MZ fallback loader stand-in\n" * 64,
    }
    src = work / "esp-files"
    for rel, data in files.items():
        p = src / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    run("mcopy", "-s", "-i", str(img), str(src / "EFI"), "::/")
    return img, [{"path": rel, "sha256": sha256_bytes(d)} for rel, d in files.items()]


def ntfs_image(work, hibernated):
    img = work / "win.img"
    with img.open("wb") as f:
        f.truncate(WIN[1])
    run("mkntfs", "--fast", "--force", "--label", "Windows", str(img))
    # ntfscp can't create directories: the test data lives in the volume root.
    files = {"thesis.txt": b"Do not lose this.\n" * 4096,
             "photo.raw": hashlib.sha512(b"photo").digest() * 16384}
    if hibernated:
        # Fast Startup / hibernation leaves hiberfil.sys starting with "hibr" (or "wake").
        files["hiberfil.sys"] = b"hibr" + bytes(4092) + b"\x01" * 4096
    src = work / "ntfs-files"
    for rel, data in files.items():
        p = src / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        run("ntfscp", "--force", str(img), str(p), rel)
    return img, [{"path": rel, "sha256": sha256_bytes(d)} for rel, d in files.items()]


def bitlocker_image(work):
    img = work / "win.img"
    data = bytearray(64 * 1024)
    data[0:3] = b"\xeb\x58\x90"
    data[3:11] = b"-FVE-FS-"
    data[160:176] = BITLOCKER_GUID
    struct.pack_into("<3Q", data, 176, FVE_META, 0, 0)
    vmk = bytes(26) + struct.pack("<H", 0x0100)  # protection 0x0100 = TPM: not suspended
    entry = struct.pack("<4H", 8 + len(vmk), 0x0002, 0x0008, 1) + vmk
    block = b"-FVE-FS-".ljust(64, b"\0") + struct.pack("<I", 48 + len(entry)).ljust(48, b"\0") + entry
    data[FVE_META:FVE_META + len(block)] = block
    data[510:512] = b"\x55\xaa"
    with img.open("wb") as f:
        f.write(data)
        f.truncate(WIN[1])
    return img


def main(argv):
    if len(argv) != 2 or argv[0] not in CASES:
        die(f"usage: install-seed.py {{{'|'.join(CASES)}}} OUTDIR")
    case, out = argv[0], Path(argv[1])
    out.mkdir(parents=True, exist_ok=True)
    disk = out / "disk.img"
    seed = {"case": case, "size": DISK, "partitions": [], "files": {}}
    new_disk(disk)
    if case in ("alongside", "refuse-bitlocker", "refuse-hibernated"):
        need("sgdisk", "mkfs.fat", "mcopy", "mkntfs", "ntfscp")
        work = out / "seed-work"
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir()
        gpt(disk)
        esp, seed["files"]["esp"] = esp_image(work)
        splice(disk, esp, ESP[0])
        if case == "refuse-bitlocker":
            win = bitlocker_image(work)
        else:
            win, seed["files"]["ntfs"] = ntfs_image(work, hibernated=case == "refuse-hibernated")
        splice(disk, win, WIN[0])
        shutil.rmtree(work)
        seed["partitions"] = [{"name": "esp", "offset": ESP[0], "size": ESP[1]},
                              {"name": "msr", "offset": MSR[0], "size": MSR[1]},
                              {"name": "windows", "offset": WIN[0], "size": WIN[1]}]
    (out / "seed.json").write_text(json.dumps(seed, indent=1) + "\n")
    print(f"install-seed: {case}: {disk} ({len(seed['partitions'])} pre-existing partitions)")


if __name__ == "__main__":
    main(sys.argv[1:])
