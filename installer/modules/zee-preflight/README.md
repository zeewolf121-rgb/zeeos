# zee-preflight (installer-disk)

Read-only BitLocker detection for every candidate disk (ADR-0003). Nothing here writes to a disk.

- `preflight.py`: probes each disk and partition from `lsblk` for `-FVE-FS-` (Vista, Windows 7+)
  and BitLocker To Go (`MSWIN4.1` + BitLocker GUID). It reports `bitlocker`, `bitlocker-suspended`
  (a VMK with a clear key), `ntfs`, `exfat` or `other`. A device that can't be read fails closed.
  BitLocker volumes, suspended or not, block resizing: the data stays encrypted on disk either way.
  The user gets steps to save the recovery key, suspend BitLocker, shrink the volume in Windows,
  and re-scan.
- `main.py`: Calamares job. Put it in `exec` before `partition`. It publishes the scan to
  globalstorage `zeePreflight` and refuses the install if a planned partition is a BitLocker volume.
  `dryRun: true` logs every read.

```bash
python3 preflight.py --dry-run                     # all disks
python3 preflight.py --dry-run --device disk.img   # one image; exit 2 = resize blocked
pytest installer/modules/zee-preflight/tests
```

Not here yet (needs the Calamares base integration): the warning view with Re-scan, the same
warning in manual partitioning, and the `install-test.yml` case.
