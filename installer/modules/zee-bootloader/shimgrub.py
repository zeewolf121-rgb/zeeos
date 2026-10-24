# SPDX-License-Identifier: GPL-3.0-or-later
"""Put Fedora's signed shim + GRUB on the target ESP (ADR-0004, P4-2 #176).

Calamares' stock `bootloader` module can't do this on Fedora: its `grub` mode runs grub2-install,
which builds an unsigned GRUB image (and Fedora's grub2-install refuses EFI targets), and its
`sb-shim` mode hard-codes x86 file names. So this job:

1. copies the Fedora-signed files that the shim and grub2-efi RPMs put in the live system's
   /boot/efi/EFI/fedora/ into the target ESP's \\EFI\\fedora\\ (a new directory: an existing,
   non-empty \\EFI\\fedora\\ belongs to another Fedora install and is refused, never overwritten);
2. writes Fedora's grub.cfg stub there, pointing at the target /boot by filesystem UUID;
3. runs grub2-mkconfig for /boot/grub2/grub.cfg on the target root.

Only \\EFI\\fedora\\ is written. \\EFI\\Microsoft\\ and \\EFI\\BOOT\\ are never opened for writing,
nothing is deleted, the ESP is never formatted. The NVRAM entry is zee-bootmenu's job (P4-7).
Every planned operation is logged first; dry_run=True only logs.

CLI (tests and manual checks):
    python3 shimgrub.py [--dry-run] --boot-uuid UUID SOURCE_DIR ESP_DIR TARGET_ROOT
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

VENDOR_DIR = "EFI/fedora"  # relative to the ESP; the only directory this job writes
SIGNED = {
    "x86_64": ("shimx64.efi", "grubx64.efi"),
    "aarch64": ("shimaa64.efi", "grubaa64.efi"),
}
# Also copied when present: MokManager / fallback and the shim CSV (all from the same RPMs).
OPTIONAL_PREFIXES = ("mm", "BOOT", "shim")
STUB = (
    "search --no-floppy --fs-uuid --set=dev {uuid}\n"
    "set prefix=($dev)/grub2\n"
    "export $prefix\n"
    "configfile $prefix/grub.cfg\n"
)


def plan_files(source: Path, arch: str) -> list[str]:
    """Names to copy from source: the arch's shim + grub (required) and the optional extras."""
    if arch not in SIGNED:
        raise ValueError(f"unsupported architecture {arch!r}")
    if not source.is_dir():
        raise FileNotFoundError(f"no signed boot files at {source}")
    names = sorted(p.name for p in source.iterdir() if p.is_file() and not p.is_symlink())
    missing = [n for n in SIGNED[arch] if n not in names]
    if missing:
        raise FileNotFoundError(f"{source} lacks {', '.join(missing)} (Fedora shim/grub2-efi RPMs)")
    keep = set(SIGNED[arch])
    keep |= {n for n in names if n.startswith(OPTIONAL_PREFIXES) and n.lower().endswith((".efi", ".csv"))}
    return sorted(keep)


def install(
    source: Path,
    esp: Path,
    target_root: Path,
    *,
    boot_uuid: str,
    arch: str,
    dry_run: bool = False,
    log: Callable[[str], None] = print,
    run: Callable[[list[str], Path], None] | None = None,
) -> list[str]:
    """Plan and (unless dry_run) perform the three steps. Returns the planned operations."""
    source, esp, target_root = Path(source), Path(esp), Path(target_root)
    if not esp.is_dir():
        raise FileNotFoundError(f"ESP not mounted at {esp}")
    if not boot_uuid or any(c.isspace() for c in boot_uuid):
        raise ValueError(f"bad /boot filesystem UUID {boot_uuid!r}")
    dest = esp / VENDOR_DIR
    if dest.is_symlink() or (dest.exists() and any(dest.iterdir())):
        raise ValueError(
            f"{dest} already exists and is not empty (another Fedora-based install?); "
            "refusing to overwrite its boot files"
        )
    names = plan_files(source, arch)
    ops = [f"mkdir {dest}"]
    ops += [f"copy {source / n} -> {dest / n}" for n in names]
    ops.append(f"write {dest / 'grub.cfg'} (stub: /boot UUID {boot_uuid})")
    ops.append(f"chroot {target_root} grub2-mkconfig -o /boot/grub2/grub.cfg")
    for op in ops:
        log(f"zee-bootloader: plan: {op}")
    if dry_run:
        log("zee-bootloader: dry run, nothing written")
        return ops

    dest.mkdir(parents=True, exist_ok=True)
    for n in names:
        shutil.copyfile(source / n, dest / n)
    (dest / "grub.cfg").write_text(STUB.format(uuid=boot_uuid), encoding="utf-8")
    (run or _chroot_run)(["grub2-mkconfig", "-o", "/boot/grub2/grub.cfg"], target_root)
    log(f"zee-bootloader: installed {len(names)} signed files into {dest}")
    return ops


def _chroot_run(cmd: list[str], target_root: Path) -> None:
    subprocess.run(["chroot", str(target_root), *cmd], check=True)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--boot-uuid", required=True)
    ap.add_argument("--arch", default="x86_64", choices=sorted(SIGNED))
    ap.add_argument("source", type=Path)
    ap.add_argument("esp", type=Path)
    ap.add_argument("target_root", type=Path)
    a = ap.parse_args(argv)
    try:
        install(a.source, a.esp, a.target_root, boot_uuid=a.boot_uuid, arch=a.arch, dry_run=a.dry_run)
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        print(f"zee-bootloader: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
