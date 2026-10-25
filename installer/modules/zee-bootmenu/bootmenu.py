# SPDX-License-Identifier: GPL-3.0-or-later
"""GRUB defaults, Windows entry and the ZeeOS NVRAM entry (ADR-0003, ADR-0004, P4-7 #179).

Runs after zee-bootloader, which put Fedora's signed shim + GRUB into \\EFI\\fedora\\. This job:

1. edits /etc/default/grub on the target: ZeeOS (the first entry) is the default, 5 s timeout,
   os-prober enabled, the menu always shown, the ZeeOS GRUB theme when the image ships it;
2. copies that theme to /boot/grub2/themes/zeeos/ (GRUB can't read a LUKS2 root);
3. writes /etc/grub.d/35_zeeos_windows, a static `chainloader /EFI/Microsoft/Boot/bootmgfw.efi`
   entry that finds the ESP by filesystem UUID, but only when that file is on the target ESP
   (os-prober still finds Windows on other disks);
4. unsets Fedora's menu_auto_hide and runs grub2-mkconfig on the target;
5. adds one NVRAM entry `ZeeOS` for \\EFI\\fedora\\shim<arch>.efi and puts it first in BootOrder
   (or last, with first=False). Every other entry keeps its number and relative order.

Unattended CI installs only (#250): with console="tty0 ttyS0,115200" (the preset's console= key,
passed on by zee-autopreset as globalstorage `zeeConsole`), step 1 also adds console=<each> to
GRUB_CMDLINE_LINUX and drops rhgb/quiet. The same edit goes into the `options` line of every BLS
entry in /boot/loader/entries/, because Fedora's grub2-mkconfig doesn't rewrite those. Interactive
installs never pass it and keep Fedora's command line.

Nothing on the ESP is written: \\EFI\\Microsoft\\ is only checked for bootmgfw.efi, never opened.
No NVRAM entry is deleted or changed; the job fails if one went missing. Every planned operation is
logged first; dry_run=True only logs and reads the current NVRAM entries. Generated titles are ASCII
(the GRUB theme's PF2 fonts cover U+0020-U+007E only, #200).

CLI (tests and manual checks):
    python3 bootmenu.py [--dry-run] [--not-first] [--console C] --esp-uuid UUID --esp-device DEV ESP_DIR TARGET_ROOT
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

LABEL = "ZeeOS"
TIMEOUT = 5
WINDOWS_LOADER = "EFI/Microsoft/Boot/bootmgfw.efi"  # relative to the ESP; checked, never opened
WINDOWS_LOADER_EFI = "\\EFI\\Microsoft\\Boot\\bootmgfw.efi"
VENDOR_DIR = "EFI/fedora"
GRUB_DEFAULTS = "etc/default/grub"
WINDOWS_SCRIPT = "etc/grub.d/35_zeeos_windows"
THEME_SOURCE = "usr/share/grub/themes/zeeos"  # in the target root, installed by the image
THEME_DEST = "boot/grub2/themes/zeeos"
WINDOWS_ENTRY = """#!/bin/sh
# Written by the ZeeOS installer (zee-bootmenu, ADR-0004): fallback entry for the Windows Boot
# Manager on the ESP with filesystem UUID {uuid}. os-prober may list it too.
cat <<'EOF'
menuentry 'Windows Boot Manager (ZeeOS fallback)' --class windows --class os --id zeeos-windows {{
	insmod part_gpt
	insmod fat
	insmod chain
	search --no-floppy --fs-uuid --set=root {uuid}
	chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}}
EOF
"""
SAFE_UUID = re.compile(r"^[0-9A-Za-z-]{4,64}$")
SHIM = re.compile(r"^shim(?!ia32)[a-z0-9]+\.efi$")  # shimx64.efi / shimaa64.efi, not shim.efi
ENTRY = re.compile(r"^Boot([0-9A-Fa-f]{4})\*?\s+(.*)$")
# Same pattern as the preset parser in installer/autoinstall/zeeos-autoinstall (a test checks it).
CONSOLE = re.compile(r"^(tty0|ttyS0|ttyAMA0)(,[0-9]+)?( (tty0|ttyS0|ttyAMA0)(,[0-9]+)?)*$")
QUIET = ("rhgb", "quiet")
BLS_DIR = "boot/loader/entries"


@dataclass
class Nvram:
    order: list[str] = field(default_factory=list)
    labels: dict[str, str] = field(default_factory=dict)  # "0003" -> "Windows Boot Manager"


def parse_efibootmgr(text: str) -> Nvram:
    """Parse `efibootmgr` output (labels end at a tab, where -v and newer versions put the path)."""
    nv = Nvram()
    for line in text.splitlines():
        if line.startswith("BootOrder:"):
            nv.order = [x.strip().upper() for x in line.split(":", 1)[1].split(",") if x.strip()]
        elif m := ENTRY.match(line):
            nv.labels[m.group(1).upper()] = m.group(2).split("\t")[0].strip()
    return nv


def split_device(dev: str) -> tuple[str, str]:
    """/dev/nvme0n1p1 -> (/dev/nvme0n1, 1); /dev/vda2 -> (/dev/vda, 2)."""
    m = re.match(r"^(/dev/\S*\d)p(\d+)$", dev) or re.match(r"^(/dev/\S*?[a-z])(\d+)$", dev)
    if not m:
        raise ValueError(f"can't tell disk and partition number of ESP device {dev!r}")
    return m.group(1), m.group(2)


def shim_name(esp: Path) -> str:
    names = sorted(p.name for p in (esp / VENDOR_DIR).glob("*.efi") if SHIM.match(p.name))
    if len(names) != 1:
        raise FileNotFoundError(f"expected one shim<arch>.efi in {esp / VENDOR_DIR}, found {names or 'none'}")
    return names[0]


def edit_defaults(text: str, values: dict[str, str]) -> str:
    """Set KEY="value" for each key (every existing assignment replaced), keep all other lines."""
    out, done = [], set()
    for line in text.splitlines():
        key = line.split("=", 1)[0].strip()
        if "=" in line and key in values:
            if key not in done:
                out.append(f'{key}="{values[key]}"')
                done.add(key)
            continue
        out.append(line)
    out += [f'{k}="{v}"' for k, v in values.items() if k not in done]
    return "\n".join(out) + "\n"


def console_args(console: str) -> list[str]:
    """"tty0 ttyS0,115200" -> ["console=tty0", "console=ttyS0,115200"]; anything else is refused."""
    if not CONSOLE.fullmatch(console):  # not .match: "$" also matches before a final "\n"
        raise ValueError(f"bad console value {console!r}")
    return [f"console={c}" for c in console.split()]


def with_console(cmdline: str, args: list[str]) -> str:
    """The command line without rhgb, quiet or any console=, then the given console= entries."""
    kept = [t for t in cmdline.split() if t not in QUIET and not t.startswith("console=")]
    return " ".join(kept + args)


# Kernel arguments that belong to the live ISO or its build, never to the installed system.
LIVE_ARGS = ("rd.live.", "root=", "rootflags=", "BOOT_IMAGE=")


def fstab_root(target_root: Path) -> tuple[str, str | None] | None:
    """(root spec, btrfs subvolume or None) from the target's /etc/fstab, written by the fstab job."""
    try:
        text = (target_root / "etc/fstab").read_text(encoding="utf-8")
    except OSError:
        return None
    for line in text.splitlines():
        f = line.split()
        if len(f) >= 4 and not f[0].startswith("#") and f[1] == "/":
            sub = next((o[len("subvol="):] for o in f[3].split(",") if o.startswith("subvol=")), None)
            return f[0], sub
    return None


def bls_normalize(text: str, root: tuple[str, str | None]) -> str:
    """Point a BLS entry copied from the image at the installed system. kiwi writes the entries at
    build time with the build host's paths (linux /home/runner/.../image-root/boot/vmlinuz-...) and
    the live options (rd.live.image, the build root's UUID); GRUB then can't find the kernel (seen
    live). /boot is a separate partition, so the paths are relative to it."""
    lines = text.splitlines()
    ver = next((l.split(None, 1)[1].strip() for l in lines if l.split(None, 1)[:1] == ["version"]), None)
    if not ver:
        m = next((re.search(r"vmlinuz-(\S+)$", l) for l in lines if l.split(None, 1)[:1] == ["linux"]), None)
        ver = m.group(1) if m else None
    if not ver:
        return text
    spec, sub = root
    out = []
    for line in lines:
        key = line.split(None, 1)[:1]
        if key == ["linux"]:
            line = f"linux /vmlinuz-{ver}"
        elif key == ["initrd"]:
            line = f"initrd /initramfs-{ver}.img"
        elif key == ["options"]:
            kept = [t for t in line.split()[1:] if t != "ro" and not t.startswith(LIVE_ARGS)]
            base = [f"root={spec}", "ro"] + ([f"rootflags=subvol={sub}"] if sub else [])
            line = "options " + " ".join(base + kept)
        out.append(line)
    return "\n".join(out) + "\n"


def bls_edits(target_root: Path, console: list[str] | None) -> dict[Path, str]:
    """New text of each BLS entry that changes: pointed at the installed system (when the target
    has an fstab root), and with the requested console= arguments."""
    out = {}
    root = fstab_root(target_root)
    for entry in sorted((target_root / BLS_DIR).glob("*.conf")):
        text = entry.read_text(encoding="utf-8")
        new = bls_normalize(text, root) if root else text
        if console is not None:
            lines = [f"options {with_console(line[len('options'):], console)}"
                     if line.split(None, 1)[:1] == ["options"] else line for line in new.splitlines()]
            new = "\n".join(lines) + "\n"
        if new != text:
            out[entry] = new
    return out


def grub_values(old: str, theme: bool, console: list[str] | None = None) -> dict[str, str]:
    values = {
        "GRUB_DEFAULT": "0",  # the first entry: the newest ZeeOS kernel (BLS entries come first)
        "GRUB_SAVEDEFAULT": "false",
        "GRUB_TIMEOUT": str(TIMEOUT),
        "GRUB_TIMEOUT_STYLE": "menu",
        "GRUB_DISABLE_OS_PROBER": "false",
    }
    if not re.search(r"^GRUB_ENABLE_BLSCFG=", old, re.M):
        values["GRUB_ENABLE_BLSCFG"] = "true"  # Fedora's default; only set if the file lacks it
    if theme:
        values["GRUB_THEME"] = "/" + THEME_DEST + "/theme.txt"
        m = re.search(r"^GRUB_TERMINAL_OUTPUT=[\"']?([^\"'\n]*)", old, re.M)
        values["GRUB_TERMINAL_OUTPUT"] = "gfxterm serial" if m and "serial" in m.group(1) else "gfxterm"
    if console:
        cur = re.findall(r"^GRUB_CMDLINE_LINUX=([\"']?)(.*?)\1[ \t]*$", old, re.M)
        cmdline = with_console(cur[-1][1] if cur else "", console)
        if re.search(r"[\"'$`\\]", cmdline):
            raise ValueError(f"GRUB_CMDLINE_LINUX {cmdline!r} has quotes or expansions; not edited")
        values["GRUB_CMDLINE_LINUX"] = cmdline
    return values


def install(
    esp: Path,
    target_root: Path,
    *,
    esp_uuid: str,
    esp_device: str,
    first: bool = True,
    dry_run: bool = False,
    console: str | None = None,
    log: Callable[[str], None] = print,
    run: Callable[[list[str]], str],
) -> list[str]:
    """Plan and (unless dry_run) perform the five steps. `run` executes a command in the target
    and returns its stdout. Returns the planned operations."""
    esp, target_root = Path(esp), Path(target_root)
    if not esp.is_dir():
        raise FileNotFoundError(f"ESP not mounted at {esp}")
    if not SAFE_UUID.match(esp_uuid or ""):
        raise ValueError(f"bad ESP filesystem UUID {esp_uuid!r}")
    disk, part = split_device(esp_device)
    loader = "\\" + VENDOR_DIR.replace("/", "\\") + "\\" + shim_name(esp)
    windows = (esp / WINDOWS_LOADER).is_file()
    theme_src = target_root / THEME_SOURCE
    theme = (theme_src / "theme.txt").is_file()
    defaults = target_root / GRUB_DEFAULTS
    old = defaults.read_text(encoding="utf-8") if defaults.is_file() else ""
    cons = console_args(console) if console else None
    values = grub_values(old, theme, cons)
    bls = bls_edits(target_root, cons)
    before = parse_efibootmgr(run(["efibootmgr"]))

    ops = [f"write {defaults}: " + " ".join(f"{k}={v}" for k, v in values.items())]
    ops += [(f"write {entry}: options with {' '.join(cons)}, without rhgb quiet; " if cons else f"write {entry}: ")
            + "kernel/initrd paths and root for the installed system" for entry in bls]
    if theme:
        ops.append(f"copy {theme_src} -> {target_root / THEME_DEST}")
    else:
        log(f"zee-bootmenu: no GRUB theme at {theme_src}, keeping the text menu")
    if windows:
        ops.append(f"write {target_root / WINDOWS_SCRIPT} (chainload {WINDOWS_LOADER_EFI} on ESP UUID {esp_uuid})")
    else:
        log(f"zee-bootmenu: no {WINDOWS_LOADER_EFI} on the target ESP; os-prober only")
    ops.append(f"chroot {target_root} grub2-editenv - unset menu_auto_hide")
    ops.append(f"chroot {target_root} grub2-mkconfig -o /boot/grub2/grub.cfg")
    ops.append(f"efibootmgr --create --disk {disk} --part {part} --label {LABEL} --loader {loader}")
    where = "first" if first else "last"
    ops.append(f"efibootmgr --bootorder: {LABEL} {where}, then {','.join(before.order) or '(empty)'} unchanged")
    for op in ops:
        log(f"zee-bootmenu: plan: {op}")
    if dry_run:
        log("zee-bootmenu: dry run, nothing written")
        return ops

    defaults.parent.mkdir(parents=True, exist_ok=True)
    defaults.write_text(edit_defaults(old, values), encoding="utf-8")
    for entry, text in bls.items():
        entry.write_text(text, encoding="utf-8")
    if theme:
        shutil.copytree(theme_src, target_root / THEME_DEST, dirs_exist_ok=True)
    if windows:
        script = target_root / WINDOWS_SCRIPT
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text(WINDOWS_ENTRY.format(uuid=esp_uuid), encoding="ascii")
        script.chmod(0o755)
    run(["grub2-editenv", "-", "unset", "menu_auto_hide"])
    run(["grub2-mkconfig", "-o", "/boot/grub2/grub.cfg"])

    if LABEL in before.labels.values():
        log(f"zee-bootmenu: an NVRAM entry {LABEL} already exists; it is kept, a new one is added")
    run(["efibootmgr", "--create", "--disk", disk, "--part", part, "--label", LABEL, "--loader", loader])
    after = parse_efibootmgr(run(["efibootmgr"]))
    new = [n for n, label in after.labels.items() if n not in before.labels and label == LABEL]
    if len(new) != 1:
        raise ValueError(f"expected one new {LABEL} NVRAM entry, found {new or 'none'}")
    rest = [n for n in before.order if n in after.labels]
    order = [new[0], *rest] if first else [*rest, new[0]]
    if after.order != order:
        run(["efibootmgr", "--bootorder", ",".join(order)])
    final = parse_efibootmgr(run(["efibootmgr"]))
    lost = [f"Boot{n} {lbl}" for n, lbl in before.labels.items() if final.labels.get(n) != lbl]
    if lost:
        raise ValueError(f"NVRAM entries changed or missing after the install: {', '.join(lost)}")
    if final.order != order:
        raise ValueError(f"BootOrder is {','.join(final.order)}, expected {','.join(order)}")
    log(f"zee-bootmenu: NVRAM entry Boot{new[0]} {LABEL} -> {loader}, BootOrder {','.join(order)}")
    return ops


def _chroot_run(target_root: Path) -> Callable[[list[str]], str]:
    def run(cmd: list[str]) -> str:
        return subprocess.run(["chroot", str(target_root), *cmd], check=True,
                              capture_output=True, text=True).stdout
    return run


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--not-first", action="store_true", help="append ZeeOS to BootOrder instead")
    ap.add_argument("--esp-uuid", required=True)
    ap.add_argument("--esp-device", required=True)
    ap.add_argument("--console", help='unattended CI only, e.g. "tty0 ttyS0,115200"')
    ap.add_argument("esp", type=Path)
    ap.add_argument("target_root", type=Path)
    a = ap.parse_args(argv)
    try:
        install(a.esp, a.target_root, esp_uuid=a.esp_uuid, esp_device=a.esp_device,
                first=not a.not_first, dry_run=a.dry_run, console=a.console, run=_chroot_run(a.target_root))
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        print(f"zee-bootmenu: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
