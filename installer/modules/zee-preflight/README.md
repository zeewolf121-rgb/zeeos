# zee-preflight (installer-disk)

Read-only checks that stop an install from touching a Windows volume that isn't safe to resize
(P4-3 #4, P4-4 #5, ADR-0003). Nothing here writes to a disk.

- `preflight.py` probes every disk and partition from `lsblk`:
  - BitLocker: `-FVE-FS-` (Vista, Windows 7+) and BitLocker To Go (`MSWIN4.1` + BitLocker GUID).
    Reports `bitlocker`, or `bitlocker-suspended` when a VMK has a clear key.
  - NTFS dirty: the `VOLUME_IS_DIRTY` flag of `$VOLUME_INFORMATION` in MFT record 3 (`$Volume`),
    read straight from the device with the update-sequence fixups applied. Reports `ntfs-dirty`.
  - NTFS hibernated (hibernation or Fast Startup): `\hiberfil.sys` starts with `hibr`/`HIBR`, read
    with `ntfsls -a` and `ntfscat` (ntfsprogs, read-only). `wake` (resumed) or no hiberfil is fine.
    Reports `ntfs-hibernated`.
  - Otherwise `ntfs`, `exfat` or `other`. A device or volume it can't read is `unreadable`
    (fail closed), and so is a missing tool.
  Each blocking kind comes with fix steps (save the recovery key and suspend BitLocker; turn off
  Fast Startup and shut down fully; `chkdsk /f`).
- `main.py` is the Calamares job. It goes in `exec` before any disk job, and it is first in the
  unattended sequence. Touched devices (`preflight.touched`): with a partition plan in globalstorage,
  every device on a disk that the plan uses; without one (unattended, before `zee-autopart`), or with a
  plan device that maps to no disk, every device except the `ZEEOS-AUTOINSTALL` preset disk. A
  touched device that is blocking or unreadable refuses the install. When
  `/run/zeeos-autoinstall/` exists, it writes `preflight: refusing to resize or install: <dev> is
  <kind>` to `fail`, and `zeeos-autoinstall` prints that as `ZEEOS_INSTALL_FAIL preflight: …`.
  The scan goes to globalstorage `zeePreflight`. Dry run (`dryRun: true`, globalstorage
  `zeeDryRun`, or `ZEE_DRY_RUN=1`) logs every read and tool call as `PLAN read-only …`.

```bash
python3 preflight.py --dry-run                     # all disks
python3 preflight.py --dry-run --device disk.img   # one image; exit 2 = resize blocked
python3 -m unittest discover -s installer/modules/zee-preflight/tests
```

The `RealNtfs` tests build volumes with `mkntfs` and `ntfscp`, the same way `vm/install-seed.py`
does, and skip when ntfs-3g/ntfsprogs are missing.

Not here yet: the warning view with Re-scan, the same warning in manual partitioning, and
`zee-preflight` in the interactive exec sequence (`installer/calamares/settings.conf` only has a
slot comment so far).
