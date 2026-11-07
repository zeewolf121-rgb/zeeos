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
(`UNLOCK_TIMEOUT`, default `BOOT_TIMEOUT`), writes the preset `luks_passphrase` + CR with `vm/qmp.py SOCK serial-type` to the installed boot's serial port. That port is a
`-chardev socket,id=ser0,path=OUT/serial.sock,server=on,wait=off,logfile=OUT/serial-installed.log` (the log is written exactly as
for a file serial), because the prompt goes to `/dev/console`, the last `console=` on the kernel command line, i.e. the serial
port, not the keyboard. The other cases keep the plain `-serial file:` log. then runs the same `boot`/`bootmenu`/`rootfs` checks as erase with `ZEEOS_ROOTFS ... luks=2`. junit
has an `unlock` check: no prompt, a plaintext root, or a passphrase that doesn't bring the system up fail it.
The installed kernel must log to the serial console (`console=ttyS0`/`ttyAMA0`) for any installed-boot check.
NVRAM (alongside, refuse-*): `vm/install-nvram.py` writes a `Windows Boot Manager` Boot#### entry (HD(ESP) +
`\EFI\Microsoft\Boot\bootmgfw.efi`) into the run's `OUT/vars.fd` copy (a fresh VARS template only has the firmware's
own entries), snapshots it (`nvram-before.json`), and after the install reads `vars.fd` again (`nvram-after.json`).
Needs python `virt-firmware` **26.9** (`virt-fw-vars`; Fedora `python3-virt-firmware`, or `pip install virt-firmware==26.9`;
`VIRT_FW_VARS` overrides the command). Missing tool = failed `nvram` check, not a skip. Rules: the Windows entry and every
entry that existed before keep title and device path and relative BootOrder order; alongside also needs a new `ZeeOS` entry
first; refuse-* must not gain `ZeeOS` or an `\EFI\fedora` entry. Firmware-added entries (PXE, shell, DVD) are tolerated
(a disk-only boot of real OVMF kept the seeded entry and added its own: DVD, PXE, setup; with the seeded stub failing to load, BDS fell through to the next entry). No check is skipped any more.
Offline self-tests: `tests/install-selftest.sh` (run by `tests/selftest.sh`).

## OEM disk boot test (#277, P5-5)

`vm/oem-boot-test.sh` boots the raw `oem` disk of the UTM bundle (aarch64 only) under QEMU + AAVMF, Secure Boot on or off.
There is no ISO: the disk is the boot drive, attached through a qcow2 overlay (the image is never modified).

```bash
DISK=out/aarch64-oem/image/ZeeOS-aarch64.aarch64-0.1.0.raw SECUREBOOT=on vm/oem-boot-test.sh
```

Env: `DISK` (required), `SECUREBOOT`, `OUT`, `TIMEOUT` (300 s; 1800 s under TCG), `SETTLE` (screenshot delay after the
last marker; 30 s, 120 s under TCG), `MIN_COLORS`, `DRY_RUN`, and `QEMU_BIN`/`QEMU_IMG`/`FW_CODE`/`FW_VARS` as in `boot-test.sh`.
Firmware and acceleration (KVM, HVF, else TCG; recorded in `OUT/accel`) are chosen as in `boot-test.sh`.

Pass marker. The oem disk has no user until the plasma-setup first-boot wizard runs (no default passwords), so
`ZEEOS_DESKTOP_READY` cannot apply, and no ZeeOS unit is needed. The cell passes when the serial console shows all of
`OEM_MARKERS` (vm/markers.sh), which the stock Fedora kernel and systemd print: `Linux version`, the switch-root
`Welcome to ...!`, `Reached target multi-user.target`, `Finished plasma-setup.service` (the first-boot oneshot that
creates the temporary `plasma-setup` user), `Started sddm.service`, `Reached target graphical.target`, and
`Started session-N.scope - Session N of User plasma-setup` (SDDM logged the wizard user in). After `SETTLE` seconds
it also requires that the session survived: any kernel audit core dump (`type=1701`) or stopped user manager
(`type=1131 unit=user@<uid>`) fails the cell (`wizard_session_ended`). It fails on any systemd
`[FAILED]` line, a kernel panic, a frozen PID 1, a timeout, or a kernel `secureboot: Secure boot enabled|disabled` line
that differs from `SECUREBOOT`. Order is not checked.

What this does not prove: that the wizard is on screen. The audit lines are rate-limited, so a missing crash line is no proof. The
screenshot (`OUT/screenshot.ppm`) is taken `SETTLE` seconds after the last marker and its distinct-colour count is
recorded in junit (`screenshot_colors`); it is report-only until `MIN_COLORS=<n>` is set (a text console has 2, a painted
Plasma wizard has hundreds). Turn the gate on once the wizard paints. A real desktop-ready marker for the wizard needs a
guest unit (desktop-shell) and is a follow-up on #277.

## UTM bundle (#278, P5-7)

`vm/utm/` builds and tests the aarch64 UTM bundle. `config.plist.in` is the UTM (QEMU backend) VM definition: `virt`
machine, UEFI boot, 4 vCPU, 4096 MiB, one VirtIO disk, `virtio-gpu-pci`, `virtio-net-pci` (shared), clipboard sharing
(the SPICE agent channel; guest tools come from the image's `spice-vdagent`), hypervisor on, RNG on, TPM off.

```bash
DISK=out/aarch64-oem/image/ZeeOS-aarch64.aarch64-0.1.0.raw VERSION=0.1.0 vm/utm/make-bundle.sh   # DRY_RUN=1 prints the steps
BUNDLE=out/utm/zeeos-0.1.0-aarch64.utm.zip vm/utm/utm-test.sh                                    # on the Apple silicon Mac
```

`make-bundle.sh`: raw -> `qemu-img convert -c` qcow2 -> `zeeos-<ver>-aarch64.utm/{config.plist,Data/<disk>.qcow2}` ->
`zeeos-<ver>-aarch64.utm.zip` (a reproducible zip: sorted entries, fixed timestamps, qcow2 stored). The UUID is derived from the name.

`utm-test.sh` unpacks the bundle (safe extract), reads machine, CPU count, memory, GPU, NIC and disk from its `config.plist`,
and boots the bundle's own qcow2 through an overlay with UTM's edk2 firmware (`$UTM_APP/Contents/Resources/qemu/edk2-aarch64-code.fd`
and the bundle's `Data/efi_vars.fd`, else `edk2-arm-vars.fd`), HVF on a Mac (KVM on an aarch64 host, else TCG, recorded in `OUT/accel`).
Pass marker: `OEM_MARKERS` as in `oem-boot-test.sh`. The disk has no user before the wizard, so `ZEEOS_DESKTOP_READY` cannot print.
If the guest announces `ZEEOS_HARDENING_CHECK`, or `REQUIRE_HARDENING=1`, then `ZEEOS_HARDENING_OK ... autoupdate=on` must follow
(`autoupdate=live-off` or any `ZEEOS_HARDENING_FAIL` fails). junit: `zeeos-utm-test`, properties `accel`, `secureboot_kernel`, `hardening`, `plist_*`.

**UTM firmware and Secure Boot: not enforced.** First real run on the owner's Mac (2026-11-07, UTM.app's
`edk2-aarch64-code.fd` and `edk2-arm-vars.fd`, HVF, the Plasma 6.8.2 oem disk from utm-disk run 42060637316): pass after 14 s,
all OEM markers, the plasma-setup wizard painted (30503 screenshot colours), and the kernel reported
`secureboot: Secure boot disabled`. UTM's default aarch64 firmware has no enrolled keys, so a UTM VM boots ZeeOS with Secure
Boot off; the signed chain is exercised by the AAVMF cells (`vm/oem-boot-test.sh`, boot-test) instead. UTM ships
`edk2-arm-vars.fd` unpadded; `utm-test.sh` pads its working copy to the code image's size, as QEMU's virt pflash requires.
Offline checks: `tests/utm-selftest.sh` (run by `tests/selftest.sh`).
