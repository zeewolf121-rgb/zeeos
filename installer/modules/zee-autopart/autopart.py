# SPDX-License-Identifier: GPL-3.0-or-later
"""zee-autopart logic (P4-9, #181). installer-disk.

Unattended (CI) partitioning for the `erase` and `luks` presets only, with the layout of
calamares/modules/partition.conf: ESP 600 MiB, ext4 /boot 2 GiB, btrfs root on the rest (inside
LUKS2 for `luks`). It only ever writes a disk that is blank: no partition table, no filesystem
signature. Anything else (an existing ESP, Windows, a second candidate disk) is refused, so it can
never format an existing ESP or touch Windows Boot Manager. Pure functions here; main.py runs them.
"""

from __future__ import annotations

ESP_MIB = 600
BOOT_MIB = 2048
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
    """The one target disk from `lsblk -J -b -o NAME,PATH,TYPE,RM,RO,SERIAL,SIZE,PTTYPE,FSTYPE,
    MOUNTPOINTS`: a writable, non-removable whole disk that is neither the preset disk nor the live
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


def mkfs_argvs(disk: str, root_dev: str) -> list[list[str]]:
    return [["mkfs.vfat", "-F", "32", "-n", "EFI", part_path(disk, 1)],
            ["mkfs.ext4", "-q", "-F", "-L", "boot", part_path(disk, 2)],
            ["mkfs.btrfs", "-q", "-f", "-L", "zeeos", root_dev]]


def mapper_name(luks_uuid: str) -> str:
    return f"luks-{luks_uuid}"


def partitions_gs(disk: str, ids: dict[str, dict[str, str]], luks_uuid: str | None) -> list[dict]:
    """globalstorage `partitions` in the shape Calamares' partition module writes, as read by
    mount, fstab, zee-espbackup and zee-bootloader. ids: device -> {uuid, partuuid}; for LUKS the
    root entry's uuid is the btrfs inside the mapper."""
    def entry(n, fs, mnt, label):
        dev = part_path(disk, n)
        return {"device": dev, "fs": fs, "fsName": fs, "mountPoint": mnt, "partlabel": label,
                "uuid": ids[dev]["uuid"], "partuuid": ids[dev]["partuuid"], "claimed": True,
                "features": {}, "partattrs": 0}
    out = [entry(1, "fat32", "/boot/efi", "EFI"), entry(2, "ext4", "/boot", "boot"),
           entry(3, "btrfs", "/", "root")]
    if luks_uuid:
        out[2]["luksMapperName"] = mapper_name(luks_uuid)
        out[2]["luksUuid"] = luks_uuid
        out[2]["uuid"] = ids["/dev/mapper/" + mapper_name(luks_uuid)]["uuid"]
    return out
