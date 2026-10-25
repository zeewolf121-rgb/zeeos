# SPDX-License-Identifier: GPL-3.0-or-later
"""Dry run of the ZeeOS Calamares sequence (P4-2, #176): print every planned disk operation.

Reads installer/calamares/settings.conf and the module configs, checks the disk-safety rules
(CONVENTIONS, ADR-0003, ADR-0004) and prints, for each exec step in order, what it would write
and where. It never opens a disk device: CI runs it where no disk may be written before
install-test (P4-8/P4-W). Exit status 1 if a rule is broken or a module or config is missing.

    python3 installer/tools/zee-plan.py [--mode erase|alongside|manual] [--luks] [CALAMARES_DIR]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml  # PyYAML: python3-pyyaml (Fedora) / python3-yaml (Ubuntu runners)

INSTALLER = Path(__file__).resolve().parents[1]

# Calamares 3.3 stock modules this sequence may use.
STOCK = {
    "welcome", "locale", "keyboard", "partition", "users", "summary", "finished", "mount",
    "unpackfs", "machineid", "fstab", "localecfg", "displaymanager", "networkcfg", "hwclock",
    "shellprocess", "removeuser", "packages", "dracut", "umount",
}
# Stock modules that must not run: they would build or write unsigned boot files (ADR-0004).
FORBIDDEN = {"bootloader", "grubcfg", "luksbootkeyfile"}

# What each exec step writes, by install mode. Steps not listed write no disk.
DISK_OPS = {
    "partition": {
        "erase": ["wipe the partition table of the chosen disk, new GPT",
                  "create ESP (FAT32, 600 MiB), /boot (ext4, 2 GiB), / (btrfs, rest)",
                  "format the three new partitions"],
        "alongside": ["shrink the chosen partition (blocked by zee-preflight for BitLocker/dirty NTFS)",
                      "create /boot (ext4, 2 GiB) and / (btrfs) in the freed space",
                      "reuse the existing ESP: mount only, never format"],
        "manual": ["apply the user's manual layout (existing partitions default to 'keep')",
                   "an existing ESP is mounted, never formatted"],
    },
    "mount": {"*": ["mount the new partitions and the ESP under the target root"]},
    "unpackfs": {"*": ["rsync the live root into the target root (/boot/efi/* excluded)"]},
    "machineid": {"*": ["write /etc/machine-id on the target root"]},
    "fstab": {"*": ["write /etc/fstab (and /etc/crypttab with LUKS) on the target root"]},
    "shellprocess@zeelivecleanup": {"*": ["delete live-only files on the target root, lock root"]},
    "removeuser": {"*": ["userdel -r liveuser on the target root"]},
    "packages@zeeremovecalamares": {"*": ["dnf remove calamares calamares-libs on the target root"]},
    "dracut": {"*": ["regenerate the initramfs in the target /boot"]},
    "zee-espbackup": {"*": ["read the ESP; write /var/lib/zeeos/esp-backup-*.tar + .sha256 on the target root"]},
    "zee-bootloader@zeeos": {"*": ["mkdir \\EFI\\fedora\\ on the ESP (refused if not empty)",
                                   "copy Fedora's signed shim + GRUB into \\EFI\\fedora\\ only",
                                   "write \\EFI\\fedora\\grub.cfg stub; grub2-mkconfig on the target /boot"]},
    "zee-bootmenu": {"*": ["write /etc/default/grub (ZeeOS default, 5 s, os-prober) on the target root",
                           "write /etc/grub.d/35_zeeos_windows if \\EFI\\Microsoft\\Boot\\bootmgfw.efi is on the ESP",
                           "grub2-mkconfig on the target /boot (no ESP write)",
                           "NVRAM: add Boot#### ZeeOS, put it first; no entry removed or renumbered"]},
    "umount": {"*": ["unmount the target"]},
}
LUKS_OPS = ["LUKS2-format the / partition (cryptsetup, luks2) before creating btrfs in it"]


class PlanError(Exception):
    pass


def load(path: Path) -> dict:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise PlanError(f"missing config {path}") from None
    if not isinstance(data, dict):
        raise PlanError(f"{path} is not a YAML mapping")
    return data


def exec_steps(settings: dict) -> list[str]:
    steps = []
    for block in settings.get("sequence", []):
        steps += block.get("exec", [])
    return steps


def module_config(calamares: Path, settings: dict, step: str) -> tuple[str, Path]:
    """(module name, its config path) for a sequence entry `module` or `module@id`."""
    name, _, iid = step.partition("@")
    conf = f"{name}.conf"
    if iid:
        inst = [i for i in settings.get("instances", []) if i.get("id") == iid and i.get("module") == name]
        if not inst:
            raise PlanError(f"{step}: no matching entry under instances")
        conf = inst[0].get("config", conf)
    return name, calamares / "modules" / conf


def check(calamares: Path) -> tuple[dict, list[str]]:
    """Validate the configuration. Returns (settings, exec steps)."""
    settings = load(calamares / "settings.conf")
    steps = exec_steps(settings)
    shown = [m for b in settings.get("sequence", []) for m in b.get("show", [])]
    for step in steps + shown:
        name, conf = module_config(calamares, settings, step)
        if name in FORBIDDEN:
            raise PlanError(f"{step}: stock module {name} is not allowed (ADR-0004)")
        if name.startswith("zee-"):
            if not (INSTALLER / "modules" / name / "module.desc").is_file():
                raise PlanError(f"{step}: installer/modules/{name}/module.desc is missing")
        elif name not in STOCK:
            raise PlanError(f"{step}: unknown module {name}")
        if "@" in step and not conf.is_file():
            raise PlanError(f"{step}: missing config {conf}")

    # The page right before the first exec block is the confirmation page. zee-summary (P4-6) adds
    # the mandatory backup checkbox (ADR-0003). The stock summary stays until the image builds the
    # zee-summary plugin; then this check requires zee-summary.
    blocks = settings.get("sequence", [])
    first_exec = next((i for i, b in enumerate(blocks) if "exec" in b), None)
    before = [m for b in blocks[:first_exec] for m in b.get("show", [])]
    pages = [m for m in shown if m in ("summary", "zee-summary")]
    if len(pages) != 1 or not before or before[-1] != pages[0]:
        raise PlanError("exactly one of summary / zee-summary, as the last page before the install")

    def pos(prefix: str) -> int:
        hits = [i for i, s in enumerate(steps) if s == prefix or s.startswith(prefix + "@")]
        if not hits:
            raise PlanError(f"{prefix} is not in the exec sequence")
        return hits[0]

    if not pos("partition") < pos("mount") < pos("unpackfs") < pos("zee-espbackup") < pos("zee-bootloader") < pos("umount"):
        raise PlanError("exec order must be partition < mount < unpackfs < zee-espbackup < zee-bootloader < umount")
    if not pos("zee-bootloader") < pos("zee-bootmenu") < pos("umount"):
        raise PlanError("exec order must be zee-bootloader < zee-bootmenu < umount (the NVRAM entry needs the shim)")
    if not pos("unpackfs") < pos("shellprocess@zeelivecleanup") < pos("removeuser"):
        raise PlanError("the live cleanup must run after unpackfs and before removeuser")

    mods = calamares / "modules"
    part = load(mods / "partition.conf")
    if part.get("luksGeneration") != "luks2":
        raise PlanError("partition.conf: luksGeneration must be luks2")
    if part.get("efiSystemPartition") != "/boot/efi":
        raise PlanError("partition.conf: efiSystemPartition must be /boot/efi")
    if part.get("defaultFileSystemType") != "btrfs":
        raise PlanError("partition.conf: defaultFileSystemType must be btrfs (Fedora's default)")
    if load(mods / "users.conf").get("doAutologin") is not False:
        raise PlanError("users.conf: doAutologin must be false on installed systems")
    if load(mods / "removeuser.conf").get("username") != "liveuser":
        raise PlanError("removeuser.conf: username must be liveuser")
    excludes = [x for e in load(mods / "unpackfs.conf").get("unpack", []) for x in e.get("exclude", [])]
    if "/boot/efi/*" not in excludes:
        raise PlanError("unpackfs.conf: /boot/efi/* must be excluded (the ESP is written only by zee-bootloader)")
    script = " ".join(
        s if isinstance(s, str) else s.get("command", "")
        for s in load(mods / "shellprocess-zeelivecleanup.conf").get("script", [])
    )
    for needle in ("10-zeeos-live-autologin.conf", "zeeos-desktop-ready", "zeeos-layout-check",
                   "zeeos-theme-check", "serial-getty", "usermod -p '!' root"):
        if needle not in script:
            raise PlanError(f"live cleanup doesn't remove {needle}")
    return settings, steps


def plan(calamares: Path, mode: str, luks: bool) -> list[str]:
    _, steps = check(calamares)
    lines = []
    for step in steps:
        ops = DISK_OPS.get(step, {})
        for op in ops.get(mode, ops.get("*", [])):
            lines.append(f"zee-plan: {step}: {op}")
        if step == "partition" and luks and mode != "manual":
            lines += [f"zee-plan: {step}: {op}" for op in LUKS_OPS]
    lines.append("zee-plan: \\EFI\\Microsoft\\ and \\EFI\\BOOT\\: never written; existing ESP: never formatted")
    lines.append("zee-plan: dry run, no disk opened")
    return lines


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mode", choices=("erase", "alongside", "manual"), default="erase")
    ap.add_argument("--luks", action="store_true")
    ap.add_argument("calamares", nargs="?", type=Path, default=INSTALLER / "calamares")
    a = ap.parse_args(argv)
    try:
        for line in plan(a.calamares, a.mode, a.luks):
            print(line)
    except PlanError as e:
        print(f"zee-plan: FAIL {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
