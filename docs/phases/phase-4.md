# Phase 4 plan: installer (Calamares), dual boot, LUKS2, install-test

**Exit criterion:** on `main`, `install-test.yml` is green for these cases (MISSION §10.3):

| Case | Seed disk | Arch | After the install and reboot from disk |
|---|---|---|---|
| (a) erase | blank 40 GB | x86_64, aarch64 | `ZEEOS_DESKTOP_READY`, GRUB menu has ZeeOS |
| (b) alongside | GPT: Windows-like ESP (`\EFI\Microsoft\Boot\bootmgfw.efi`, NVRAM entry `Windows Boot Manager`) + NTFS with data | x86_64 | `ZEEOS_DESKTOP_READY`, GRUB menu has ZeeOS **and** a Windows entry; pre-existing ESP files and NTFS data checksums unchanged; the `Windows Boot Manager` NVRAM entry still exists |
| (c) LUKS2 | blank 40 GB | x86_64, aarch64 | passphrase unlock at boot, then `ZEEOS_DESKTOP_READY`; root is `crypto_LUKS` version 2 |
| (d) refuse | (b) with a BitLocker-signature volume, then with a dirty/hibernated NTFS volume | x86_64 | installer refuses the resize (`ZEEOS_INSTALL_FAIL preflight: …`); every disk checksum unchanged |

Secure Boot on for every case. Case (b) is x86_64 only: Windows-on-ARM dual boot isn't a v1 target, and the aarch64 cells already run under TCG.

**Boot chain:** the installed system boots Fedora's signed shim and GRUB exactly as shipped (ADR-0004). The installer writes `/etc/default/grub`, runs `grub2-mkconfig`, adds one NVRAM entry `ZeeOS`, and never touches `\EFI\Microsoft\` or any Windows `BootOrder` entry except putting ZeeOS first.

## Scope rules for this phase

- **Calamares 3.3 from Fedora** with our modules in `/installer/modules/` (ADR-0003). Package source under review: proposed [ADR-0011](../adr/0011-installer-package-wayland-only.md) rebuilds Fedora's Calamares without `setxkbmap` (#210). No Calamares fork, no compiled modules: Python `job` modules and QML `view` modules only. If a goal needs C++, stop and open a `decision` issue.
- **Disk safety** (CONVENTIONS): every module that can write to a disk, partition table, ESP or NVRAM is `installer-disk`, has a dry-run mode the tests use, logs every planned operation first, never formats an existing ESP and never removes or overwrites Windows Boot Manager. `installer-disk` PRs need Opus authoring + cross-review, not owner approval.
- **Tests first for detection code.** `zee-preflight` and `zee-espbackup` get pytest suites on small fixture images built by scripts in `tests/fixtures/` (never committed binaries over 1 MB).
- **The live session isn't the installed system.** Calamares removes the live-only parts on the target: `liveuser` and its home, `etc/sddm.conf.d/10-zeeos-live-autologin.conf`, the guest test units (`zeeos-*-check`, `zeeos-desktop-ready`) and passwordless root. Auto-login is off on installed systems (MISSION §4).
- **Unattended mode for CI only.** A raw virtio disk with **serial** `ZEEOS-AUTOINSTALL` (a filesystem label can't hold 17 characters: FAT allows 11, ext4 16) makes a live-session unit run Calamares non-interactively. The guest reads `/dev/disk/by-id/virtio-ZEEOS-AUTOINSTALL`: `key=value` lines from byte 0, NUL-padded to 1 MiB. Keys: `case` (`erase|luks|alongside|refuse-bitlocker|refuse-hibernated`), `user`, `password`, `luks_passphrase`, all generated per run by `vm/install-test.sh` (#180). Without that disk nothing runs. The preset can't skip `zee-preflight`.
- **Use what Fedora ships.** Package names are checked with `dnf repoquery` in the build container, not guessed.

## Marker protocol (fixed here so P4-8 and P4-9 can run in parallel)

Live session, only when the `ZEEOS-AUTOINSTALL` disk is present:

```
ZEEOS_INSTALL_START case=<erase|alongside|luks|refuse>
ZEEOS_INSTALL_DONE case=<…>             # Calamares finished; the guest powers off
ZEEOS_INSTALL_FAIL <module>: <reason>   # any failure, including a preflight refusal
```

Installed system, first boot (a unit installed only by the test preset):

```
ZEEOS_BOOTMENU zeeos=1 windows=<0|1> default=ZeeOS timeout=5
ZEEOS_ROOTFS fstype=<btrfs|…> luks=<0|2>
ZEEOS_DESKTOP_READY
```

The harness (P4-8) checksums the seed disk's pre-existing partitions before the install and after the reboot, outside the guest.

## Issues (concurrency cap: MISSION §11)

| ID | Title | Agent | Model | Arch | Budget | Deps |
|---|---|---|---|---|---|---|
| P4-1 | Packages: `calamares`, `os-prober`, `ntfs-3g`/`ntfsprogs`, `cryptsetup`, `parted`, `dosfstools`, `efibootmgr`, plus whatever `dnf repoquery` shows Calamares' Fedora package needs; refreshed locks; a "Install ZeeOS" launcher in the live session | image-builder | claude | both | small 15 | — `parallel-safe` |
| P4-2 | Calamares base configuration in `/installer`: `settings.conf` sequence, ZeeOS branding descriptor, `unpackfs` from the live image, `partition` (erase / alongside / manual, LUKS2 option, Fedora's default filesystem), `users` (auto-login off), `locale` (English, `en_US.UTF-8` default; no other language promised or tested, ADR-0009), `bootloader` (shim + GRUB per ADR-0004), and the live-session cleanup on the target. Wires `zee-*` modules into the sequence as they land | installer-engineer | claude | both | large 80 | P4-1 · `installer-disk` |
| P4-3 | #4 `zee-preflight`: BitLocker detection, block resize | installer-engineer | claude | both | medium 40 | — · `installer-disk` |
| P4-4 | #5 `zee-preflight`: dirty/hibernated NTFS detection, block resize | installer-engineer | claude | both | medium 40 | P4-3 (same module) · `installer-disk` |
| P4-5 | `zee-espbackup` job: tar the existing ESP to the target root with checksums before any bootloader write; never format an existing ESP | installer-engineer | claude | both | medium 40 | — · `installer-disk` |
| P4-6 | `zee-summary` view: mandatory "I have a backup" checkbox, per-disk list of every planned change; Install stays disabled until checked | installer-engineer | claude | both | medium 40 | P4-2 |
| P4-7 | `zee-bootmenu` job: `/etc/default/grub` (ZeeOS default, 5 s), os-prober plus the static Windows chainload entry by ESP UUID, NVRAM entry `ZeeOS`; never touches `\EFI\Microsoft\`; GRUB theme from `/branding/grub/` once it exists | installer-engineer | claude | both | medium 40 | P4-2 · `installer-disk` |
| P4-8 | `vm/install-test.sh`: seed disks for cases (a)–(d), the `ZEEOS-AUTOINSTALL` preset disk, install run, reboot from disk, markers, outside-the-guest checksums, junit per case; fixture self-tests in `tests/` | vm-integrator | claude | both | large 80 | — `parallel-safe` (marker protocol above) |
| P4-9 | Unattended install unit in the live overlay: on the `ZEEOS-AUTOINSTALL` disk, run Calamares with the preset, print the live markers; the test preset installs the first-boot marker unit on the target | installer-engineer | claude | both | medium 40 | P4-2 · `installer-disk` |
| P4-10 | GRUB theme art (`/branding/grub/`): `theme.txt`, backgrounds, `.pf2` fonts, readable at 800×600 and in text mode, REUSE entries | theme-designer | codex | both | medium 40 | — `parallel-safe` |

## Orchestrator tasks (interactive session, not opened by autopilot)

- **P4-W** `install-test.yml`: matrix over the cases and arches above, Secure Boot on, needs the ISO from `build-iso`; runs `vm/install-test.sh` and uploads serial logs, junit and checksums. Workflow edit, so it's `needs-human` and owner-approved. After P4-8.
- **Milestone:** `Phase 4: Installer` exists; this plan's issues go into it.

## Lanes

```
Lane F:  P4-1 ─► P4-2 ─► P4-6, P4-7, P4-9 ─┐
Lane F:  P4-3 ─► P4-4;  P4-5 ───────────────┤
Lane A:  P4-8 ─► P4-W (orchestrator) ───────┴─► integration checkpoint (exit test on main)
Lane B:  P4-10 (theme art; P4-7 uses it when present, not on the exit path)
```

## Carried over

- Phase 3 leftovers that don't block this phase: #131/#137 (window decoration art), #136 (layout baselines), #170 (dark repaint).
- Opened early (owner, 2026-10-23) while Phase 3 finishes, to overlap the phases.
