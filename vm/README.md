# /vm

Owner: `vm-integrator` (see docs/agents.md). Other agents: open an issue instead of editing here.

## Boot harness

```bash
ARCH=x86_64 SECUREBOOT=on ISO=out/zeeos.iso vm/boot-test.sh
DRY_RUN=1 vm/boot-test.sh      # print the QEMU command only
```

Env: `ARCH`, `SECUREBOOT=on|off`, `ISO`, `DISK` (seed image, attached via a qcow2 overlay so it is never modified),
`OUT`, `TIMEOUT` (default 600 s), `MARKER` (default `ZEEOS_DESKTOP_READY`: the string the in-guest
desktop-ready unit must print on the serial console; P1-9 must agree on it).

Theme check (phase-2 marker protocol): if the guest prints `ZEEOS_THEME_CHECK`, the harness also requires
`ZEEOS_THEME_OK` and `ZEEOS_DARK_READY` (fails on `ZEEOS_THEME_FAIL` or after `THEME_TIMEOUT`, default 600 s per
marker), and screenshots after each (`screenshot-light.ppm`, `screenshot-dark.ppm`; `screenshot.ppm` is still taken
at the desktop-ready marker). Without `ZEEOS_THEME_CHECK` nothing changes. junit properties: `theme_check`,
`boot_seconds`, `idle_total_kb`/`idle_available_kb`/`idle_used_kb` (from `ZEEOS_MEM`), and `light_dark_diff_pct`
(`imgdiff.py`, report-only).

Gating diff (P3-8): after the run, `tests/imgdiff_gate.py` compares each `screenshot-<step>.ppm` with
`build/arch/$ARCH/baselines/<step>.ppm` (override with `BASELINES`). Only steps with a baseline are compared; with no
baseline directory or no matching file nothing is gated. Clock/cursor regions are masked via `masks.txt` in the
baselines dir (`STEP|* X Y W H`, negative X/Y from the right/bottom edge); the threshold is 1.0 % of unmasked pixels
(channel tolerance 8). A failure sets the result to `imgdiff-gate`; junit property `imgdiff_gate` is `pass|fail|skip`.

Layout check (phase-3 marker protocol): if the guest prints `ZEEOS_LAYOUT_CHECK`, the harness also requires
`ZEEOS_LAYOUT_OK mode=windows|mac|hybrid`, in that order after the theme steps, with the same
`THEME_TIMEOUT` and settle delay, and screenshots after each (`screenshot-<mode>.ppm`).
`ZEEOS_LAYOUT_FAIL` fails the cell. junit has one `boot.step` testcase per step (later steps are
`skipped` after a failure) and a `layout_check` property. Without the announce nothing changes.
`QEMU_BIN`/`FW_CODE`/`FW_VARS` override the emulator and firmware; `tests/selftest.sh` uses them to replay fixture
serial logs offline.

Outputs in `OUT`: `serial.log`, `screenshot.ppm` (QMP screendump), `junit.xml`, `accel` (`kvm`/`hvf`/`tcg`).

SB on uses Microsoft-keys enrolled OVMF vars (Fedora edk2 `OVMF_VARS.secboot.fd`); Fedora and Debian/Ubuntu
firmware paths are probed. aarch64 SB-on needs an AAVMF vars file with keys enrolled; if none is found the run
falls back to the stock vars and is not a true Secure Boot test.

`make boot-test` still needs wiring to this script (the Makefile is outside this agent's scope).

Install test (P4-8, docs/phases/phase-4.md): `vm/install-test.sh` with `CASE=erase|luks|alongside|refuse-bitlocker|refuse-hibernated`
seeds `OUT/disk.img` (`vm/install-seed.py`; the partitioned cases need gdisk, dosfstools, mtools, ntfs-3g), attaches the
ISO and the `ZEEOS-AUTOINSTALL` preset disk, waits for `ZEEOS_INSTALL_DONE`/`_FAIL`, boots the installed disk with the
same NVRAM vars, and checks `ZEEOS_BOOTMENU`, `ZEEOS_ROOTFS`, `ZEEOS_DESKTOP_READY`. `vm/install-checksums.py` hashes the
pre-existing data outside the guest: whole partitions plus the disk size and both GPT copies for the refuse cases.
For alongside it first validates the real post-install GPT (`layout`: both copies valid and identical, disk not
truncated, ESP/MSR/Windows kept with the same type, unique GUID and start; only Windows may end earlier), then hashes
individual ESP/NTFS files read from the partitions' current ranges. `DRY_RUN=1 vm/install-test.sh` (and
`install-seed.py --dry-run`) prints every planned write and writes nothing; a normal run prints the same seed plan
first. Preset transport (for #181, until the architect adds it to the plan): a raw virtio
disk with serial `ZEEOS-AUTOINSTALL`, `key=value` lines from byte 0, NUL-padded to 1 MiB; keys `case`, `user`, `password`,
`luks_passphrase`.
LUKS (case c): the harness boots the installed disk, waits for the passphrase prompt on the serial console
(`UNLOCK_TIMEOUT`, default `BOOT_TIMEOUT`), types the preset `luks_passphrase` with `vm/qmp.py SOCK type` (one QMP
`send-key` per key through the usb-kbd, because the serial port is an output-only file and plymouth/systemd-ask-password
read the keyboard), then runs the same `boot`/`bootmenu`/`rootfs` checks as erase with `ZEEOS_ROOTFS ... luks=2`. junit
has an `unlock` check: no prompt, a plaintext root, or a passphrase that doesn't bring the system up fail it.
The installed kernel must log to the serial console (`console=ttyS0`/`ttyAMA0`) for any installed-boot check.
NVRAM (alongside, refuse-*): `vm/install-nvram.py` writes a `Windows Boot Manager` Boot#### entry (HD(ESP) +
`\EFI\Microsoft\Boot\bootmgfw.efi`) into the run's `OUT/vars.fd` copy (a fresh VARS template only has the firmware's
own entries), snapshots it (`nvram-before.json`), and after the install reads `vars.fd` again (`nvram-after.json`).
Needs python `virt-firmware` **26.9** (`virt-fw-vars`; Fedora `python3-virt-firmware`, or `pip install virt-firmware==26.9`;
`VIRT_FW_VARS` overrides the command). Missing tool = failed `nvram` check, not a skip. Rules: the Windows entry and every
entry that existed before keep title and device path and relative BootOrder order; alongside also needs a new `ZeeOS` entry
first; refuse-* must not gain `ZeeOS` or an `\EFI\fedora` entry. Firmware-added entries (PXE, shell, DVD) are tolerated
(verified with a real OVMF boot). No check is skipped any more.
Offline self-tests: `tests/install-selftest.sh` (run by `tests/selftest.sh`).
