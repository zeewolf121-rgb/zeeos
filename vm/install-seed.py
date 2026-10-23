#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the install-test seed disk for one case (docs/phases/phase-4.md, P4-8).

  install-seed.py [--dry-run] CASE OUTDIR      CASE: erase | luks | alongside | refuse-bitlocker | refuse-hibernated

Writes OUTDIR/disk.img (sparse raw, 40 GiB) and OUTDIR/seed.json. Everything is built from image
files: nothing is mounted, and the target must be a regular file (never a block device or symlink).
The whole plan is printed before the first write; --dry-run prints it and writes nothing at all
(not even OUTDIR), and reports missing tools instead of failing on them.

seed.json lists the pre-existing partitions (offset, size), their GPT identity (type, unique GUID,
first and last LBA, set here rather than left to sgdisk so it is known up front) and, for
alongside, the pre-existing ESP and NTFS files with SHA-256, so install-checksums.py can prove the
install left them alone. gpt.shrink names the partition an alongside install may shrink.

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
import uuid
from functools import partial
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
LAYOUT = [("esp", ESP, GUID_ESP, "EFI system partition"), ("msr", MSR, GUID_MSR, "Microsoft reserved partition"),
          ("windows", WIN, GUID_BASIC, "Basic data partition")]
TOOLS = ("sgdisk", "mkfs.fat", "mcopy", "mkntfs", "ntfscp")

# Same on-disk layout as installer/modules/zee-preflight's fixtures (#4): OEM id at 3, BitLocker
# GUID at 160, FVE metadata offsets at 176, a v2 metadata block whose VMK is TPM-protected.
BITLOCKER_GUID = bytes.fromhex("3bd66749292ed84a8399f6a339e3d001")
FVE_META = 0x2000

ESP_FILES = {
    "EFI/Microsoft/Boot/bootmgfw.efi": b"MZ install-test stand-in for Windows Boot Manager\n" * 64,
    "EFI/Microsoft/Boot/BCD": hashlib.sha512(b"bcd").digest() * 128,
    "EFI/Boot/bootx64.efi": b"MZ fallback loader stand-in\n" * 64,
}
# ntfscp can't create directories: the test data lives in the volume root.
NTFS_FILES = {"thesis.txt": b"Do not lose this.\n" * 4096,
              "photo.raw": hashlib.sha512(b"photo").digest() * 16384}
# Fast Startup / hibernation leaves hiberfil.sys starting with "hibr" (or "wake").
HIBERFIL = b"hibr" + bytes(4092) + b"\x01" * 4096


def die(msg, code=2):
    print(f"install-seed: {msg}", file=sys.stderr)
    sys.exit(code)


def run(*cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def cmd(*args):
    """A plan step that runs one command."""
    return "+ " + " ".join(args), partial(run, *args)


def manifest(files):
    return [{"path": rel, "sha256": hashlib.sha256(d).hexdigest()} for rel, d in files.items()]


def unsafe_target(path):
    """Why path must not be written (None if it is absent or a regular file)."""
    if path.is_symlink() or (path.exists() and not stat.S_ISREG(path.lstat().st_mode)):
        return f"{path} exists and is not a regular file; refusing to write"
    return None


def new_disk(path):
    """Create the sparse disk. Never follows a symlink: a reused OUT must not redirect the write."""
    if why := unsafe_target(path):
        die(why)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "wb") as f:
        f.truncate(DISK)


def sparse(path, size):
    with path.open("wb") as f:
        f.truncate(size)


def write_tree(root, files):
    for rel, data in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)


def fresh_dir(path):
    shutil.rmtree(path, ignore_errors=True)
    path.mkdir()


def splice(disk, part_img, offset):
    """Copy a partition image into the disk at offset (sparse-friendly, never past its end)."""
    with part_img.open("rb") as src, disk.open("r+b") as dst:
        dst.seek(offset)
        while chunk := src.read(4 * MiB):
            if chunk.count(0) == len(chunk):
                dst.seek(len(chunk), os.SEEK_CUR)
            else:
                dst.write(chunk)


def bitlocker_image(img):
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


def plan(case, out):
    """(steps, tools, seed): every write this case makes, in order, as (description, action)."""
    disk, work = out / "disk.img", out / "seed-work"
    seed = {"case": case, "size": DISK, "partitions": [], "files": {}}
    steps = [(f"create directory {out}", partial(out.mkdir, parents=True, exist_ok=True)),
             (f"create sparse {disk} ({DISK >> 30} GiB, regular file only)", partial(new_disk, disk))]
    if case not in ("alongside", "refuse-bitlocker", "refuse-hibernated"):
        return steps + [(f"write {out / 'seed.json'}", partial(write_seed, out, seed))], (), seed
    steps.append((f"recreate scratch directory {work}", partial(fresh_dir, work)))
    disk_guid = str(uuid.uuid4()).upper()
    steps.append(cmd("sgdisk", "--zap-all", str(disk)))
    gpt = []
    for n, (name, (off, size), typ, label) in enumerate(LAYOUT, start=1):
        pguid = str(uuid.uuid4()).upper()
        first, last = off // 512, (off + size) // 512 - 1
        steps.append(cmd("sgdisk", f"--new={n}:{first}:{last}", f"--typecode={n}:{typ}",
                         f"--partition-guid={n}:{pguid}", f"--change-name={n}:{label}", str(disk)))
        gpt.append({"name": name, "type": typ, "guid": pguid, "first": first, "last": last})
        seed["partitions"].append({"name": name, "offset": off, "size": size})
    steps.append(cmd("sgdisk", f"--disk-guid={disk_guid}", str(disk)))
    seed["gpt"] = {"disk_guid": disk_guid, "partitions": gpt, "shrink": ["windows"] if case == "alongside" else []}

    esp, esp_src = work / "esp.img", work / "esp-files"
    steps += [cmd("mkfs.fat", "-F", "32", "-n", "SYSTEM", "-C", str(esp), str(ESP[1] // 1024)),
              (f"write {len(ESP_FILES)} ESP files under {esp_src}", partial(write_tree, esp_src, ESP_FILES)),
              cmd("mcopy", "-s", "-i", str(esp), str(esp_src / "EFI"), "::/"),
              (f"splice {esp} into {disk} at byte {ESP[0]}", partial(splice, disk, esp, ESP[0]))]
    seed["files"]["esp"] = manifest(ESP_FILES)

    win = work / "win.img"
    if case == "refuse-bitlocker":
        steps.append((f"write a BitLocker volume header into {win}", partial(bitlocker_image, win)))
    else:
        files = {**NTFS_FILES, **({"hiberfil.sys": HIBERFIL} if case == "refuse-hibernated" else {})}
        ntfs_src = work / "ntfs-files"
        steps += [(f"create sparse {win} ({WIN[1] >> 30} GiB)", partial(sparse, win, WIN[1])),
                  cmd("mkntfs", "--fast", "--force", "--label", "Windows", str(win)),
                  (f"write {len(files)} NTFS files under {ntfs_src}", partial(write_tree, ntfs_src, files))]
        steps += [cmd("ntfscp", "--force", str(win), str(ntfs_src / rel), rel) for rel in files]
        seed["files"]["ntfs"] = manifest(files)
    steps += [(f"splice {win} into {disk} at byte {WIN[0]}", partial(splice, disk, win, WIN[0])),
              (f"remove scratch directory {work}", partial(shutil.rmtree, work)),
              (f"write {out / 'seed.json'}", partial(write_seed, out, seed))]
    return steps, TOOLS, seed


def write_seed(out, seed):
    (out / "seed.json").write_text(json.dumps(seed, indent=1) + "\n")


def main(argv):
    dry = bool(argv) and argv[0] == "--dry-run"
    argv = argv[1:] if dry else argv
    if len(argv) != 2 or argv[0] not in CASES:
        die(f"usage: install-seed.py [--dry-run] {{{'|'.join(CASES)}}} OUTDIR")
    case, out = argv[0], Path(argv[1])
    # Refused in both modes, before anything is planned or written.
    if why := unsafe_target(out / "disk.img"):
        die(why)
    steps, tools, seed = plan(case, out)
    missing = [t for t in tools if shutil.which(t) is None]
    mode = "dry-run, nothing will be written" if dry else f"{len(steps)} steps"
    print(f"install-seed: {case}: plan ({mode}):", file=sys.stderr)
    for i, (desc, _) in enumerate(steps, start=1):
        print(f"  {i:2}. {desc}", file=sys.stderr)
    if missing:
        msg = f"needs {', '.join(missing)} on PATH (gdisk, dosfstools, mtools, ntfs-3g)"
        if not dry:
            die(msg)
        print(f"install-seed: dry-run: {msg}", file=sys.stderr)
    if dry:
        print(f"install-seed: dry-run: {case}: {len(steps)} steps planned, nothing written")
        return
    for i, (desc, action) in enumerate(steps, start=1):
        print(f"install-seed: [{i}/{len(steps)}] {desc}", file=sys.stderr)
        action()
    print(f"install-seed: {case}: {out / 'disk.img'} ({len(seed['partitions'])} pre-existing partitions)")


if __name__ == "__main__":
    main(sys.argv[1:])
