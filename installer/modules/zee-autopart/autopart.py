# SPDX-License-Identifier: GPL-3.0-or-later
"""zee-autopart logic (P4-9, #181). installer-disk.

Unattended (CI) partitioning with the layout of calamares/modules/partition.conf: ESP 600 MiB,
ext4 /boot 2 GiB, btrfs root on the rest (inside LUKS2 for `luks`).
- `erase` / `luks` only ever write a disk that is blank: no partition table, no filesystem
  signature. Anything else (an existing ESP, Windows) is refused.
- `alongside` needs a GPT disk with exactly one ESP and the Windows NTFS volume as the last
  partition. It shrinks that volume only as far as needed (ntfsresize without --force, so a dirty or
  hibernated volume stops it), adds /boot and root after it and reuses the ESP without formatting it.
  BitLocker or any other partition after the NTFS volume is refused.
A second candidate disk is always refused. Pure functions here; main.py runs them.
"""

from __future__ import annotations

import re

ESP_MIB = 600
BOOT_MIB = 2048
ROOT_MIN_MIB = 20 * 1024
SLACK_MIB = 1024
NTFS_MARGIN_MIB = 1024  # kept free inside Windows beyond ntfsresize's minimum
ESP_TYPE = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
MSDATA_TYPE = "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"
SECTOR = 512
LSBLK_COLS = "NAME,PATH,TYPE,RM,RO,SERIAL,SIZE,PTTYPE,FSTYPE,MOUNTPOINTS,PARTN,START,PARTTYPE"
PRESET_SERIAL = "ZEEOS-AUTOINSTALL"
SKIP_PREFIXES = ("loop", "sr", "zram", "ram", "fd")


class AutopartError(Exception):
    pass


def _has_signature(dev: dict) -> bool:
    return bool(dev.get("pttype") or dev.get("fstype") or dev.get("children"))


def _in_use(dev: dict) -> bool:
    if any(dev.get("mountpoints") or []) or dev.get("mountpoint"):
        return True
    return any(_in_use(c) for c in dev.get("children") or [])


def pick_disk(lsblk: dict) -> dict:
    """The one target disk from `lsblk -J -b -o` LSBLK_COLS: a writable, non-removable whole disk that is neither the preset disk nor the live
    medium nor in use. Exactly one must exist."""
    cands = []
    for dev in lsblk.get("blockdevices", []):
        name = dev.get("name", "")
        if dev.get("type") != "disk" or name.startswith(SKIP_PREFIXES):
            continue
        if dev.get("ro") in (True, "1", 1) or dev.get("rm") in (True, "1", 1):
            continue
        if (dev.get("serial") or "").strip() == PRESET_SERIAL or _in_use(dev):
            continue
        cands.append(dev)
    if len(cands) != 1:
        names = ", ".join(d.get("path") or d.get("name", "?") for d in cands) or "none"
        raise AutopartError(f"need exactly one target disk, found {len(cands)} ({names})")
    return cands[0]


def check_blank(disk: dict) -> None:
    if _has_signature(disk):
        raise AutopartError(
            f"{disk.get('path')} is not blank (partition table or filesystem present); "
            "unattended erase only writes blank disks")
    if int(disk.get("size") or 0) < (ESP_MIB + BOOT_MIB + 20 * 1024 + 2) << 20:
        raise AutopartError(f"{disk.get('path')} is smaller than the 23 GiB minimum")


def part_path(disk: str, n: int) -> str:
    """/dev/vda + 1 -> /dev/vda1; /dev/nvme0n1 + 1 -> /dev/nvme0n1p1."""
    return f"{disk}p{n}" if disk[-1].isdigit() else f"{disk}{n}"


def parted_argv(disk: str) -> list[str]:
    esp_end = 1 + ESP_MIB
    boot_end = esp_end + BOOT_MIB
    return ["parted", "-s", "-a", "optimal", disk, "--",
            "mklabel", "gpt",
            "mkpart", "EFI", "fat32", "1MiB", f"{esp_end}MiB", "set", "1", "esp", "on",
            "mkpart", "boot", "ext4", f"{esp_end}MiB", f"{boot_end}MiB",
            "mkpart", "root", "btrfs", f"{boot_end}MiB", "100%"]


def mkfs_argvs(disk: str, root_dev: str, boot_partn: int = 2,
               esp_partn: int | None = 1) -> list[list[str]]:
    """esp_partn None: the ESP already exists (alongside) and is never formatted."""
    esp = [["mkfs.vfat", "-F", "32", "-n", "EFI", part_path(disk, esp_partn)]] if esp_partn else []
    return esp + [["mkfs.ext4", "-q", "-F", "-L", "boot", part_path(disk, boot_partn)],
                  ["mkfs.btrfs", "-q", "-f", "-L", "zeeos", root_dev]]


def mapper_name(luks_uuid: str) -> str:
    return f"luks-{luks_uuid}"


def _mib_floor(sectors: int) -> int:
    return sectors * SECTOR >> 20


def _mib_ceil(sectors: int) -> int:
    return -(-sectors * SECTOR >> 20)


def plan_alongside(disk: dict) -> dict:
    """Where ZeeOS goes next to Windows, from the target disk's lsblk entry (with children
    carrying PARTN, START (sectors), SIZE (bytes), PARTTYPE, FSTYPE). Returns the existing ESP and
    NTFS devices, the NTFS partition number, its new size in MiB (None: no shrink needed), the MiB
    range for /boot and the start of root (root runs to the end), and the two new partition numbers.
    Refuses anything it can't do without touching the ESP or another partition's data."""
    path = disk.get("path")
    if (disk.get("pttype") or "").lower() != "gpt":
        raise AutopartError(f"{path}: alongside needs a GPT disk")
    parts = sorted(disk.get("children") or [], key=lambda p: int(p.get("start") or 0))
    if not parts:
        raise AutopartError(f"{path}: no partitions, nothing to install alongside")
    for p in parts:
        if (p.get("fstype") or "").lower() == "bitlocker":
            raise AutopartError(f"{p.get('path')} is BitLocker-encrypted; not resizing it")
    esps = [p for p in parts if (p.get("parttype") or "").lower() == ESP_TYPE]
    if len(esps) != 1 or (esps[0].get("fstype") or "").lower() != "vfat":
        raise AutopartError(f"{path}: need exactly one FAT ESP, found {len(esps)}")
    win = parts[-1]
    if (win.get("fstype") or "").lower() != "ntfs" or \
            (win.get("parttype") or "").lower() != MSDATA_TYPE:
        raise AutopartError(f"{path}: the last partition ({win.get('path')}) is not an NTFS "
                            "data volume; nothing to shrink")
    start = int(win["start"])
    if start * SECTOR % (1 << 20):
        raise AutopartError(f"{win.get('path')} does not start on a MiB boundary")
    win_start = _mib_floor(start)
    win_mib = int(win["size"]) >> 20
    # The GPT backup takes the last 33 sectors: stop one whole MiB before the end.
    usable_end = (int(disk["size"]) >> 20) - 1
    win_end = _mib_ceil(start + int(win["size"]) // SECTOR)
    need = BOOT_MIB + ROOT_MIN_MIB + SLACK_MIB
    free = usable_end - win_end
    new_win = None
    if free < need:
        new_win = win_mib - (need - free)
        if new_win <= 0:
            raise AutopartError(f"{path}: too small to install alongside Windows")
        win_end = win_start + new_win
    used = {int(p["partn"]) for p in parts}
    free_nums = [n for n in range(1, 129) if n not in used][:2]
    return {"esp": esps[0]["path"], "esp_partn": int(esps[0]["partn"]), "ntfs": win["path"], "ntfs_partn": int(win["partn"]),
            "ntfs_new_mib": new_win, "boot_start": win_end, "boot_end": win_end + BOOT_MIB,
            "boot_partn": free_nums[0], "root_partn": free_nums[1]}


def ntfs_min_bytes(info: str) -> int:
    """The smallest size from `ntfsresize --info` output."""
    m = re.search(r"You might resize at (\d+) bytes", info)
    if not m:
        raise AutopartError("ntfsresize --info gave no minimum size (dirty or hibernated volume?)")
    return int(m.group(1))


def check_shrink(plan: dict, info: str) -> None:
    if plan["ntfs_new_mib"] is None:
        return
    want = (plan["ntfs_new_mib"] - NTFS_MARGIN_MIB) << 20
    if ntfs_min_bytes(info) > want:
        raise AutopartError(f"{plan['ntfs']}: Windows needs more space than the "
                            f"{plan['ntfs_new_mib']} MiB left after making room for ZeeOS")


def alongside_argvs(disk: str, plan: dict) -> list[tuple[list[str], str | None]]:
    """(argv, stdin) in order. The NTFS filesystem shrinks first, then its partition to the same
    size in place (sfdisk -N keeps start, type, GUID, name and attributes; never wipes signatures),
    then /boot and root go into the space after it. The ESP is not in this list."""
    out: list[tuple[list[str], str | None]] = []
    if plan["ntfs_new_mib"] is not None:
        size = str(plan["ntfs_new_mib"] << 20)
        dev = plan["ntfs"]
        out += [(["ntfsresize", "--no-progress-bar", "--no-action", "--size", size, dev], "y\n"),
                (["ntfsresize", "--no-progress-bar", "--size", size, dev], "y\n"),
                (["sfdisk", "--wipe", "never", "--wipe-partitions", "never",
                  "-N", str(plan["ntfs_partn"]), disk], f", {plan['ntfs_new_mib']}MiB\n")]
    out.append((["parted", "-s", "-a", "optimal", disk, "--",
                 "mkpart", "boot", "ext4", f"{plan['boot_start']}MiB", f"{plan['boot_end']}MiB",
                 "mkpart", "root", "btrfs", f"{plan['boot_end']}MiB", "100%"], None))
    return out


def partitions_gs(disk: str, ids: dict[str, dict[str, str]], luks_uuid: str | None,
                  nums: tuple[int, int, int] = (1, 2, 3)) -> list[dict]:
    """globalstorage `partitions` in the shape Calamares' partition module writes, as read by
    mount, fstab, zee-espbackup and zee-bootloader. ids: device -> {uuid, partuuid}; for LUKS the
    root entry's uuid is the btrfs inside the mapper. nums: ESP, /boot and root partition numbers."""
    def entry(n, fs, mnt, label):
        dev = part_path(disk, n)
        return {"device": dev, "fs": fs, "fsName": fs, "mountPoint": mnt, "partlabel": label,
                "uuid": ids[dev]["uuid"], "partuuid": ids[dev]["partuuid"], "claimed": True,
                "features": {}, "partattrs": 0}
    out = [entry(nums[0], "fat32", "/boot/efi", "EFI"), entry(nums[1], "ext4", "/boot", "boot"),
           entry(nums[2], "btrfs", "/", "root")]
    if luks_uuid:
        out[2]["luksMapperName"] = mapper_name(luks_uuid)
        out[2]["luksUuid"] = luks_uuid
        out[2]["uuid"] = ids["/dev/mapper/" + mapper_name(luks_uuid)]["uuid"]
    return out
