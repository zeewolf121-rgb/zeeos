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
Not yet implemented and reported as skipped in junit: typing the LUKS passphrase at boot, and the Windows Boot Manager
NVRAM entry check. Offline self-tests: `tests/install-selftest.sh` (run by `tests/selftest.sh`).
