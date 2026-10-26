# SPDX-License-Identifier: GPL-3.0-or-later
"""zee-preflight: read-only BitLocker and hibernated/dirty NTFS detection (ADR-0003, #4, #5).

BitLocker layouts follow the libbde format notes and libblkid's bitlocker prober:
- Windows 7+ BitLocker: OEM id "-FVE-FS-" at 3, BitLocker GUID at 160, FVE metadata offsets at 176.
- BitLocker To Go:      OEM id "MSWIN4.1" at 3, BitLocker GUID at 424, FVE metadata offsets at 440.
- Windows Vista:        OEM id "-FVE-FS-" at 3, FVE metadata offset at 56.
"Suspended" means a VMK is protected with a clear key (protection type 0x0000).

NTFS (#5), never mounted:
- dirty: VOLUME_IS_DIRTY (0x0001) in the $VOLUME_INFORMATION attribute of MFT record 3 ($Volume),
  read straight from the device with the update-sequence fixups applied.
- hibernated (hibernation or Windows Fast Startup): \\hiberfil.sys starts with "hibr" (any case),
  the test libntfs-3g's ntfs_volume_check_hiberfile makes. Read with ntfsls/ntfscat (ntfsprogs),
  which open the volume read-only. No hiberfil.sys means not hibernated; any other tool failure,
  including a zero exit with diagnostics on stderr, makes the volume unreadable, and unreadable
  fails closed.

This module never writes: every device is opened O_RDONLY and the tools only read.
"""
import argparse
import json
import os
import re
import struct
import subprocess
import sys
import threading

SECTOR = 512
BITLOCKER_GUID = bytes.fromhex("3bd66749292ed84a8399f6a339e3d001")  # 4967d63b-2e29-4ad8-8399-f6a339e3d001
FVE_SIG = b"-FVE-FS-"
TOGO_SIG = b"MSWIN4.1"
VMK_ENTRY, VMK_VALUE, CLEAR_KEY = 0x0002, 0x0008, 0x0000
METADATA_BLOCK_HEADER = 64  # v2 FVE metadata block header
METADATA_HEADER = 48

BITLOCKER = "bitlocker"
SUSPENDED = "bitlocker-suspended"
HIBERNATED = "ntfs-hibernated"
DIRTY = "ntfs-dirty"
UNREADABLE = "unreadable"
BLOCKING = (BITLOCKER, SUSPENDED, HIBERNATED, DIRTY)
REFUSE = BLOCKING + (UNREADABLE,)  # a touched device of one of these kinds stops the install

VOLUME_IS_DIRTY = 0x0001
AT_VOLUME_INFORMATION, AT_END = 0x70, 0xFFFFFFFF
MFT_VOLUME = 3  # MFT record number of $Volume
HIBERFIL = "hiberfil.sys"
PRESET_SERIAL = "ZEEOS-AUTOINSTALL"
TOOL_TIMEOUT = 120  # seconds for one ntfsls/ntfscat run

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

HIBERNATED_STEPS = """\
{path} is a hibernated Windows volume (Fast Startup or hibernation). ZeeOS will not resize it:
Windows would resume from a memory image that no longer matches the disk and lose data.
In Windows:
  1. Turn off Fast Startup: Control Panel > Power Options > Choose what the power buttons do >
     Change settings that are currently unavailable > clear "Turn on fast startup" > Save changes.
  2. Shut down fully: open Command Prompt and run  shutdown /s /t 0
  3. Start this installer again and press Re-scan.
"""

DIRTY_STEPS = """\
{path} is an NTFS volume marked dirty: Windows did not shut down cleanly or wants a disk check.
ZeeOS will not resize it until Windows has repaired it.
In Windows:
  1. Open Command Prompt as administrator and run  chkdsk /f C:  (the letter of this volume).
     For the Windows system drive answer Y and restart: the check runs before Windows starts.
  2. Shut down fully: run  shutdown /s /t 0
  3. Start this installer again and press Re-scan.
"""

UNREADABLE_STEPS = """\
{path} could not be checked for BitLocker, hibernation or a dirty NTFS flag ({why}).
Resizing it is blocked until it can be read.
"""

STEPS = {BITLOCKER: FIX_STEPS, SUSPENDED: FIX_STEPS, HIBERNATED: HIBERNATED_STEPS,
         DIRTY: DIRTY_STEPS}


def fix_steps(path, kind, why=""):
    return STEPS.get(kind, UNREADABLE_STEPS).format(path=path, kind=kind, why=why or kind)


class ProbeError(Exception):
    """A device or volume that could not be read: the caller fails closed."""


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

    def tool(self, argv, limit=64 << 20, head=False):
        """Run a read-only ntfsprogs tool: (rc, stdout[:limit], stderr). With `head`, stops
        after `limit` bytes and kills the tool (a real hiberfil.sys is gigabytes); that counts
        as rc 0. Without it, output longer than `limit` is incomplete and raises ProbeError."""
        if self.dry_run:
            self.log.append("PLAN read-only " + " ".join(argv))
        try:
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, env=dict(os.environ, LC_ALL="C"))
        except OSError as e:
            raise ProbeError(f"{argv[0]}: {e.strerror or e}") from None
        # A hung tool must not stall the job until the runner's timeout: kill it after TOOL_TIMEOUT.
        expired = threading.Event()

        def expire():
            expired.set()
            proc.kill()

        timer = threading.Timer(TOOL_TIMEOUT, expire)
        timer.start()
        try:
            out = proc.stdout.read(limit)
            full = len(out) >= limit
            if full:
                proc.kill()
            proc.stdout.close()
            err = proc.stderr.read(4096).decode(errors="replace")
            proc.stderr.close()
            rc = proc.wait()
        finally:
            timer.cancel()
        if expired.is_set():
            raise ProbeError(f"{argv[0]}: no answer after {TOOL_TIMEOUT}s")
        if full and not head:
            raise ProbeError(f"{argv[0]}: output longer than {limit} bytes, listing incomplete")
        return (0 if full else rc), out, err


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


def ntfs_geometry(head):
    """(bytes per cluster, MFT byte offset, MFT record size) from an NTFS boot sector."""
    bps, spc = struct.unpack_from("<HB", head, 11)
    if bps not in (512, 1024, 2048, 4096) or spc == 0:
        raise ProbeError("NTFS boot sector has an invalid geometry")
    spc = 1 << (256 - spc) if spc > 0x80 else spc  # large clusters: stored as a negative shift
    cluster = bps * spc
    mft_lcn = struct.unpack_from("<Q", head, 48)[0]
    cpr = struct.unpack_from("<b", head, 64)[0]
    rec = 1 << -cpr if cpr < 0 else cpr * cluster
    if not 256 <= rec <= 65536 or not mft_lcn:
        raise ProbeError("NTFS boot sector has an invalid MFT location")
    return cluster, mft_lcn * cluster, rec


def apply_fixups(rec):
    """Undo the update sequence of one MFT record (each 512-byte stride ends in the USN)."""
    if rec[:4] != b"FILE":
        raise ProbeError("$Volume MFT record has no FILE signature")
    usa_ofs, usa_count = struct.unpack_from("<HH", rec, 4)
    if usa_count < 2 or usa_ofs + 2 * usa_count > len(rec) or (usa_count - 1) * 512 > len(rec):
        raise ProbeError("$Volume MFT record has a bad update sequence")
    rec = bytearray(rec)
    usn = bytes(rec[usa_ofs:usa_ofs + 2])
    for i in range(1, usa_count):
        end = i * 512
        if rec[end - 2:end] != usn:
            raise ProbeError("$Volume MFT record is torn (update sequence mismatch)")
        rec[end - 2:end] = rec[usa_ofs + 2 * i:usa_ofs + 2 * i + 2]
    return bytes(rec)


def volume_info_offset(rec):
    """Byte offset of the $VOLUME_INFORMATION flags (u16) inside a fixed-up $Volume record."""
    pos = struct.unpack_from("<H", rec, 20)[0]
    while pos + 24 <= len(rec):
        atype, alen = struct.unpack_from("<II", rec, pos)
        if atype == AT_END:
            break
        if alen < 24 or pos + alen > len(rec):
            raise ProbeError("$Volume MFT record has a bad attribute")
        if atype == AT_VOLUME_INFORMATION:
            if rec[pos + 8]:
                raise ProbeError("$VOLUME_INFORMATION is not resident")
            vlen, voff = struct.unpack_from("<IH", rec, pos + 16)
            if vlen < 12 or voff + 12 > alen:
                raise ProbeError("$VOLUME_INFORMATION is too short")
            return pos + voff + 10
        pos += alen
    raise ProbeError("$Volume has no $VOLUME_INFORMATION attribute")


def ntfs_volume_flags(path, reader, head):
    """The $VOLUME_INFORMATION flags of an NTFS volume, read without mounting it."""
    _, mft, rec_size = ntfs_geometry(head)
    rec = apply_fixups(reader.read(path, mft + MFT_VOLUME * rec_size, rec_size))
    return struct.unpack_from("<H", rec, volume_info_offset(rec))[0]


def _tool_error(name, rc, err):
    return f"{name} failed: {' '.join(err.split())[:120] or f'rc={rc}'}"


def ntfs_hibernated(path, reader):
    """True if \\hiberfil.sys holds a hibernation image (Windows hibernation or Fast Startup)."""
    # ntfsls can print "Failed to read index block" and still exit 0 (its readdir error is
    # not propagated), so any diagnostic means the listing may be incomplete: fail closed.
    rc, out, err = reader.tool(["ntfsls", "-a", path])
    if rc != 0 or err.strip():
        raise ProbeError(_tool_error("ntfsls", rc, err))
    names = [n for n in out.decode("utf-8", "replace").splitlines() if n.strip().lower() == HIBERFIL]
    if not names:
        return False
    rc, out, err = reader.tool(["ntfscat", path, names[0].strip()], limit=4096, head=True)
    if rc != 0 or err.strip():  # a header read with diagnostics is not a clean header
        raise ProbeError(_tool_error(f"ntfscat {names[0].strip()}", rc, err))
    # libntfs-3g treats a hiberfil.sys under 4096 bytes (even empty) as a hibernated
    # non-system volume, so a short read is refused before the signature is compared.
    return len(out) < 4096 or out[:4].lower() == b"hibr"


def probe(path, reader):
    """Classify one device: bitlocker, bitlocker-suspended, ntfs-dirty, ntfs-hibernated, ntfs,
    exfat or other. Raises ProbeError or OSError when it can't tell (the caller fails closed)."""
    head = reader.read(path, 0, SECTOR)
    offsets = _metadata_offsets(head)
    if offsets is None:
        oem = head[3:11]
        if oem == b"NTFS    ":
            if ntfs_volume_flags(path, reader, head) & VOLUME_IS_DIRTY:
                return DIRTY
            return HIBERNATED if ntfs_hibernated(path, reader) else "ntfs"
        return {b"EXFAT   ": "exfat"}.get(oem, "other")
    for off in offsets:
        if off and _has_clear_key(reader.read(path, off, 64 * 1024)):
            return SUSPENDED
    return BITLOCKER


def lsblk_devices(lsblk):
    """[{path, type, disk, serial}] for every disk and partition of `lsblk -J -l -p -o
    PATH,TYPE,PKNAME,SERIAL`; `disk` is the whole disk a partition belongs to."""
    devs = [d for d in lsblk.get("blockdevices", []) if d.get("type") in ("disk", "part")]
    serial = {d["path"]: (d.get("serial") or "").strip() for d in devs if d["type"] == "disk"}
    out = []
    for d in devs:
        disk = d["path"] if d["type"] == "disk" else (d.get("pkname") or "")
        out.append({"path": d["path"], "type": d["type"], "disk": disk, "serial": serial.get(disk, "")})
    return out


def candidates():
    """Every disk and partition the installer could touch (all disks, not only the first)."""
    out = subprocess.run(["lsblk", "-J", "-l", "-p", "-o", "PATH,TYPE,PKNAME,SERIAL"],
                         check=True, capture_output=True, text=True).stdout
    return lsblk_devices(json.loads(out))


def scan(paths, reader):
    """Probe every path. Returns ({path: kind}, [blocking messages], {path: why unreadable})."""
    found, blocks, why = {}, [], {}
    for path in paths:
        try:
            kind = probe(path, reader)
        except (OSError, struct.error, ProbeError) as e:
            # Fail closed: a volume we cannot read could be BitLocker, hibernated or dirty.
            found[path] = UNREADABLE
            why[path] = str(e)
            blocks.append(fix_steps(path, UNREADABLE, str(e)))
            continue
        found[path] = kind
        if kind in BLOCKING:
            blocks.append(fix_steps(path, kind))
    return found, blocks, why


def touched(devices, found, planned):
    """The probed devices this install may write or resize, in `devices` order.

    `devices` comes from lsblk_devices(); `planned` are the device paths of the chosen layout
    (globalstorage `partitions`). With a plan, every device on a disk the plan uses counts:
    resizing a partition rewrites its disk's table, and a new partition may reuse an old name.
    Without a plan (the unattended sequence runs this job before zee-autopart picks the disk)
    every device counts, and so does a plan with a device that maps to no known disk (fail closed).
    The ZEEOS-AUTOINSTALL preset disk is never written and never counts."""
    disk_of = {d["path"]: d["disk"] for d in devices}
    known = {d["disk"] for d in devices}
    disks = set()
    for p in planned:
        disk = disk_of.get(p) or parent_disk(p)
        if disk not in known:
            disks = None  # can't tell which disk this plan writes: every disk counts
            break
        disks.add(disk)
    return [d["path"] for d in devices
            if d["path"] in found and d["serial"] != PRESET_SERIAL
            and (not disks or d["disk"] in disks)]


def parent_disk(path):
    """/dev/sda4 -> /dev/sda, /dev/nvme0n1p4 -> /dev/nvme0n1, /dev/vda -> /dev/vda: a planned
    partition that doesn't exist yet has no lsblk entry."""
    m = re.match(r"^(/dev/(?:nvme\d+n\d+|mmcblk\d+|loop\d+|nbd\d+))p\d+$", path) or \
        re.match(r"^(/dev/(?:[shv]d[a-z]+|xvd[a-z]+))\d+$", path)
    return m.group(1) if m else path


def refusal(found, why, paths):
    """(one-line reason for the ZEEOS_INSTALL_FAIL marker, full fix steps), or None if the
    devices in `paths` are safe."""
    bad = [p for p in paths if found.get(p) in REFUSE]
    if not bad:
        return None
    short = "; ".join(f"{p} is {found[p]}" + (f" ({why[p]})" if p in why else "") for p in bad)
    return (f"refusing to resize or install: {short}",
            "".join(fix_steps(p, found[p], why.get(p, "")) for p in bad))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true", help="log every planned operation")
    ap.add_argument("--device", action="append", help="probe this path instead of all disks")
    args = ap.parse_args(argv)
    reader = Reader(dry_run=args.dry_run)
    paths = args.device or [d["path"] for d in candidates()]
    if args.dry_run:
        reader.log.append(f"PLAN probe {len(paths)} device(s): {' '.join(paths)}")
    found, blocks, _ = scan(paths, reader)
    for line in reader.log:
        print(line, file=sys.stderr)
    print(json.dumps({"devices": found, "resize_blocked": bool(blocks)}, indent=2))
    for msg in blocks:
        print(msg, file=sys.stderr)
    return 2 if blocks else 0


if __name__ == "__main__":
    sys.exit(main())
