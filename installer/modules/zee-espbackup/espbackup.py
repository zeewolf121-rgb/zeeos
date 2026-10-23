# SPDX-License-Identifier: GPL-3.0-or-later
"""Back up an existing EFI System Partition before any bootloader write (ADR-0003, #177).

The ESP is only read: every file under it goes into an uncompressed tar on the *target* root,
next to a SHA-256 manifest. Nothing on the ESP is opened for writing, renamed or deleted, and
the ESP is never formatted. Every planned operation is logged before it happens; with
dry_run=True only the log is produced.

CLI (tests and manual checks):
    python3 espbackup.py [--dry-run] ESP_DIR TARGET_ROOT
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import os
import sys
import tarfile
from collections.abc import Callable
from pathlib import Path

BACKUP_DIR = "var/lib/zeeos"  # relative to the target root


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def esp_files(esp: Path) -> list[Path]:
    """Regular files under the ESP, sorted, as paths relative to it. Symlinks are skipped (FAT has none)."""
    out = []
    for root, dirs, files in os.walk(esp, followlinks=False):
        dirs.sort()
        for name in sorted(files):
            p = Path(root, name)
            if p.is_file() and not p.is_symlink():
                out.append(p.relative_to(esp))
    return out


def backup(
    esp: Path,
    target_root: Path,
    *,
    dry_run: bool = False,
    log: Callable[[str], None] = print,
    now: dt.datetime | None = None,
) -> Path | None:
    """Back up esp into target_root/BACKUP_DIR. Returns the tar path (None for an empty ESP or a dry run)."""
    esp, target_root = Path(esp), Path(target_root)
    if not esp.is_dir():
        raise FileNotFoundError(f"ESP not mounted at {esp}")
    if esp.resolve() == target_root.resolve() or target_root.resolve().is_relative_to(
        esp.resolve()
    ):
        raise ValueError(
            f"target {target_root} is on the ESP {esp}; refusing to write there"
        )

    files = esp_files(esp)
    if not files:
        log(f"zee-espbackup: ESP {esp} is empty, nothing to back up")
        return None

    stamp = (now or dt.datetime.now(dt.UTC)).strftime("%Y%m%dT%H%M%SZ")
    dest = target_root / BACKUP_DIR
    tar_path = dest / f"esp-backup-{stamp}.tar"
    sums_path = dest / f"esp-backup-{stamp}.sha256"
    total = sum((esp / f).stat().st_size for f in files)
    log(
        f"zee-espbackup: plan: read {len(files)} files ({total} bytes) from {esp} (read-only)"
    )
    log(f"zee-espbackup: plan: mkdir -p {dest}")
    log(f"zee-espbackup: plan: write {tar_path}")
    log(f"zee-espbackup: plan: write {sums_path}")
    if dry_run:
        log("zee-espbackup: dry run, nothing written")
        return None

    dest.mkdir(parents=True, exist_ok=True)
    lines = []
    with tarfile.open(tar_path, "w", format=tarfile.PAX_FORMAT) as tar:
        for rel in files:
            tar.add(esp / rel, arcname=rel.as_posix(), recursive=False)
            lines.append(f"{sha256(esp / rel)}  {rel.as_posix()}\n")
    sums_path.write_text("".join(lines), encoding="utf-8")
    # The ESP can hold machine secrets (e.g. BitLocker recovery hints): root-only backup files.
    for p in (tar_path, sums_path):
        p.chmod(0o600)
    log(f"zee-espbackup: wrote {tar_path} ({len(files)} files) and {sums_path}")
    return tar_path


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("esp", type=Path)
    ap.add_argument("target_root", type=Path)
    a = ap.parse_args(argv)
    try:
        backup(a.esp, a.target_root, dry_run=a.dry_run)
    except (OSError, ValueError) as e:
        print(f"zee-espbackup: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
