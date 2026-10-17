# ZeeOS Architecture

> Status: **Phase 0 draft, waiting for owner approval.** Decisions marked *Proposed* in `docs/adr/` are not final until their PR merges after cross-review (docs/adr/README.md).

## 1. What ZeeOS is

ZeeOS is a Linux distribution built on top of an existing base distro (see ADR-0001). It ships:

- an original hybrid desktop on KDE Plasma 6 / KWin (Wayland only) that mixes Windows 11, macOS and Linux design ideas,
- a branded Calamares installer with safe dual-boot support,
- signed hybrid ISOs for x86_64 and aarch64, and a prebuilt UTM bundle for Apple Silicon Macs.

v1 reuses the base distro's packages, kernel, shim and signing chain. ZeeOS writes custom code only for the parts that make it different: the desktop experience, the installer safety checks, branding and the build/test pipeline.

## 2. Component map

```
                         ┌──────────────────────────────────────────┐
  make iso ARCH=…  ───►  │ /build  (kiwi-ng image description)      │
                         │   common/  packages, overlays, services  │
                         │   arch/x86_64/  arch/aarch64/  (diffs)   │
                         └───────────────┬──────────────────────────┘
                                         │ pulls in
        ┌───────────────┬────────────────┼────────────────┬───────────────┐
        ▼               ▼                ▼                ▼               ▼
   /desktop        /branding        /installer        /security        /vm
   Plasma 6 cfg,   themes, icons,   Calamares cfg +   nftables, SELinux UTM bundle,
   KWin scripts,   wallpapers,      custom modules    policy, updates,  QEMU/OVMF
   launcher, dock, fonts, Plymouth, (BitLocker,       SSH, Secure Boot  harness
   layout switcher SDDM, GRUB theme  Fast Startup,    chain docs
                                     ESP backup)
                                         │
                                         ▼
                                  /tests  boot / install / visual tests
                                         │
                                         ▼
                                 /.github  CI, signing, release
```

## 3. Boot chain (v1)

```
UEFI firmware ─► shim (signed by Microsoft, from base distro)
              ─► GRUB2 (signed by base distro) with ZeeOS theme
              ─► kernel (signed by base distro, unmodified)
              ─► initramfs (dracut) ─► systemd ─► SDDM ─► Plasma (Wayland)
```

- ZeeOS does **not** build or sign its own kernel, shim or GRUB in v1. That is the only way to boot with Secure Boot on stock Windows PCs without asking users to enroll keys.
- Any out-of-tree module (none planned for v1) would need MOK enrollment. That path is written up in `security/secure-boot.md` (Phase 5).
- Installed systems reuse the existing EFI System Partition. GRUB lists ZeeOS and Windows Boot Manager, found by os-prober or a static chainload entry.

## 4. Architecture isolation

Everything is shared except files under `build/arch/<arch>/`:

| Concern            | x86_64                         | aarch64                          |
|--------------------|--------------------------------|----------------------------------|
| Firmware in tests  | OVMF (`edk2-ovmf`)             | AAVMF (`edk2-aarch64`)           |
| Boot loader files  | `shimx64.efi`, `grubx64.efi`   | `shimaa64.efi`, `grubaa64.efi`   |
| Legacy BIOS        | optional (GRUB i386-pc)        | none                             |
| Extra packages     | microcode, Intel Mac/T2 notes  | VM guest tools (spice/qemu-ga)   |
| CI runner          | `ubuntu-24.04`                 | self-hosted macOS ARM64 (D9, [setup](ci/macos-arm64-runner.md)) |

If a desktop, installer or branding file needs an `if arch == …`, that is a design smell. Move the difference into `build/arch/`.

## 5. Build

- One entry point: `make iso ARCH=x86_64|aarch64`. It runs the build inside a pinned container (`build/container/Containerfile`) so the host OS does not matter.
- Output goes to `out/zeeos-<ver>-<arch>.iso`, plus a package manifest and a build log.
- Reproducibility: package repos are pinned to a dated snapshot, `SOURCE_DATE_EPOCH` is derived from the git commit time, and the container image is pinned by digest. Bit-for-bit identical ISOs are a goal tracked in CI, not a v1 promise.

## 6. Testing strategy

| Layer          | Tool                                    | Where                         |
|----------------|-----------------------------------------|-------------------------------|
| Static         | shellcheck, actionlint, yamllint, gitleaks, REUSE | `security.yml`      |
| Boot           | QEMU + OVMF/AAVMF, Secure Boot on/off, serial log + screenshot via QMP | `boot-test.yml` |
| Install        | QEMU + unattended Calamares, pre-seeded fake Windows disk (NTFS + ESP with `bootmgfw.efi` stub) | `install-test.yml` |
| Visual         | screenshot diff against approved baselines | `visual-regression.yml`  |
| Manual         | real hardware checklist per release      | release issue                |

"Desktop reached" is checked inside the guest, not guessed from a screenshot. A systemd unit in test images writes a marker to the serial console when `plasmashell` is up on Wayland.

## 7. Repository layout

```
/build        image description, arch diffs, build container      (image-builder)
/installer    Calamares settings, branding, custom modules       (installer-engineer)
/desktop      Plasma/KWin config, scripts, launcher, dock        (desktop-shell)
/branding     themes, icons, wallpapers, fonts, sounds + LICENSES (theme-designer)
/security     hardening, firewall, MAC policy, update channel    (security-hardener)
/vm           UTM bundle, VM definitions                          (vm-integrator)
/tests        QEMU harness, test cases, baselines                 (vm-integrator)
/.github      workflows, templates, labels                        (ci-engineer)
/docs         architecture, ADRs, conventions, phase plans        (architect)
/docs/user    per-platform install guides, changelog              (docs-writer)
/scripts      repo tooling (agent-doc sync, GitHub bootstrap)     (ci-engineer)
```

## 8. Open risks

1. **Calamares on Fedora.** Fedora's own KDE edition installs with Anaconda, so the Fedora Calamares package gets less testing. Mitigation: pin the version and run `install-test.yml` on every installer change. Fallback: ADR-0003.
2. **aarch64 CI capacity.** GitHub's `ubuntu-24.04-arm` runners have no nested KVM on every plan. Decided (D9): aarch64 builds and tests run on a self-hosted Apple Silicon runner (HVF acceleration). Risk now: one machine is a single point of failure; `ubuntu-24.04-arm` + TCG stays as the slow fallback.
3. **Secure Boot in CI.** Testing Secure Boot ON needs OVMF variable stores with Microsoft keys enrolled (`OVMF_VARS.secboot.fd`). These ship in Fedora's `edk2-ovmf`. The aarch64 equivalent needs to be checked in Phase 1.
4. **ISO size.** The full Plasma desktop plus Arabic fonts and locales has to fit under 4 GB. Today's Fedora KDE live ISO is about 2.5–3 GB, so there is room, but the package list gets a size check in CI.
5. **Base release cadence.** Fedora releases every ~6 months and supports each release for ~13 months. ZeeOS has to rebase twice a year (see ADR-0001).
