# SPDX-License-Identifier: GPL-3.0-or-later
"""zee-preflight: read-only BitLocker detection on every candidate disk (ADR-0003).

Layouts follow the libbde format notes and libblkid's bitlocker prober:
- Windows 7+ BitLocker: OEM id "-FVE-FS-" at 3, BitLocker GUID at 160, FVE metadata offsets at 176.
- BitLocker To Go:      OEM id "MSWIN4.1" at 3, BitLocker GUID at 424, FVE metadata offsets at 440.
- Windows Vista:        OEM id "-FVE-FS-" at 3, FVE metadata offset at 56.
"Suspended" means a VMK is protected with a clear key (protection type 0x0000).

This module never writes: every device is opened O_RDONLY.
"""
import argparse
import json
import os
import struct
import subprocess
import sys

SECTOR = 512
BITLOCKER_GUID = bytes.fromhex("3bd66749292ed84a8399f6a339e3d001")  # 4967d63b-2e29-4ad8-8399-f6a339e3d001
FVE_SIG = b"-FVE-FS-"
TOGO_SIG = b"MSWIN4.1"
VMK_ENTRY, VMK_VALUE, CLEAR_KEY = 0x0002, 0x0008, 0x0000
METADATA_BLOCK_HEADER = 64  # v2 FVE metadata block header
METADATA_HEADER = 48

BITLOCKER = "bitlocker"
SUSPENDED = "bitlocker-suspended"
UNREADABLE = "unreadable"
BLOCKING = (BITLOCKER, SUSPENDED)

FIX_STEPS = """\
{path} is encrypted with BitLocker ({kind}). ZeeOS will not resize it: Linux tools
cannot shrink an encrypted Windows volume without destroying it.
In Windows:
  1. Save your BitLocker recovery key: Settings > Privacy & security > Device encryption
     (or Control Panel > BitLocker Drive Encryption > Back up your recovery key).
     Keep it off this computer, on paper or another device.
  2. Suspend BitLocker: Control Panel > BitLocker Drive Encryption > Suspend protection.
     This keeps Windows from asking for the recovery key after ZeeOS adds its boot menu.
  3. Make room for ZeeOS: Disk Management > right-click the volume > Shrink Volume.
  4. Restart into this installer and press Re-scan. Install ZeeOS into the free space.
"""


class Reader:
    """Read-only device access. In dry-run mode every operation is logged first."""

    def __init__(self, dry_run=False, log=None):
        self.dry_run = dry_run
        self.log = log if log is not None else []

    def read(self, path, offset, length):
        if self.dry_run:
            self.log.append(f"PLAN read-only {path} offset={offset} length={length}")
        fd = os.open(path, os.O_RDONLY)
        try:
            return os.pread(fd, length, offset)
        finally:
            os.close(fd)


def _metadata_offsets(head):
    oem = head[3:11]
    if oem == TOGO_SIG and head[424:440] == BITLOCKER_GUID:
        return list(struct.unpack_from("<3Q", head, 440))
    if oem == FVE_SIG:
        if head[160:176] == BITLOCKER_GUID:
            return list(struct.unpack_from("<3Q", head, 176))
        return [struct.unpack_from("<Q", head, 56)[0]]  # Vista
    return None


def _has_clear_key(block):
    """True if the FVE metadata block holds a VMK protected by a clear key (BitLocker suspended)."""
    if len(block) < METADATA_BLOCK_HEADER + METADATA_HEADER or block[:8] != FVE_SIG:
        return False
    size = struct.unpack_from("<I", block, METADATA_BLOCK_HEADER)[0]
    pos = METADATA_BLOCK_HEADER + METADATA_HEADER
    end = min(len(block), METADATA_BLOCK_HEADER + size)
    while pos + 8 <= end:
        entry_size, entry_type, value_type = struct.unpack_from("<3H", block, pos)
        if entry_size < 8:
            break
        # VMK value: GUID(16) + FILETIME(8) + unknown(2) + protection type(2).
        if entry_type == VMK_ENTRY and value_type == VMK_VALUE and pos + 36 <= end:
            if struct.unpack_from("<H", block, pos + 8 + 26)[0] == CLEAR_KEY:
                return True
        pos += entry_size
    return False


def probe(path, reader):
    """Classify one device: bitlocker, bitlocker-suspended, ntfs, exfat or other."""
    head = reader.read(path, 0, SECTOR)
    offsets = _metadata_offsets(head)
    if offsets is None:
        oem = head[3:11]
        return {b"NTFS    ": "ntfs", b"EXFAT   ": "exfat"}.get(oem, "other")
    for off in offsets:
        if off and _has_clear_key(reader.read(path, off, 64 * 1024)):
            return SUSPENDED
    return BITLOCKER


def candidates():
    """Every disk and partition the installer could touch (all disks, not only the first)."""
    out = subprocess.run(["lsblk", "-J", "-l", "-p", "-o", "PATH,TYPE"],
                         check=True, capture_output=True, text=True).stdout
    return [d["path"] for d in json.loads(out)["blockdevices"] if d["type"] in ("disk", "part")]


def scan(paths, reader):
    """Probe every path. Returns ({path: kind}, [blocking messages])."""
    found, blocks = {}, []
    for path in paths:
        try:
            kind = probe(path, reader)
        except (OSError, struct.error) as e:
            # Fail closed: a volume we cannot read could be BitLocker.
            found[path] = UNREADABLE
            blocks.append(f"{path} could not be checked for BitLocker ({e}). "
                          "Resizing is blocked until it can be read.\n")
            continue
        found[path] = kind
        if kind in BLOCKING:
            blocks.append(FIX_STEPS.format(path=path, kind=kind))
    return found, blocks


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true", help="log every planned operation")
    ap.add_argument("--device", action="append", help="probe this path instead of all disks")
    args = ap.parse_args(argv)
    reader = Reader(dry_run=args.dry_run)
    paths = args.device or candidates()
    if args.dry_run:
        reader.log.append(f"PLAN probe {len(paths)} device(s): {' '.join(paths)}")
    found, blocks = scan(paths, reader)
    for line in reader.log:
        print(line, file=sys.stderr)
    print(json.dumps({"devices": found, "resize_blocked": bool(blocks)}, indent=2))
    for msg in blocks:
        print(msg, file=sys.stderr)
    return 2 if blocks else 0


if __name__ == "__main__":
    sys.exit(main())
