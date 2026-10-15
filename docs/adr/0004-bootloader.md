# ADR-0004: Bootloader

- Status: **Proposed** (needs owner approval)
- Date: 2026-10-16

## Decision (proposed)

**GRUB 2 through the base distro's signed shim**, with a custom ZeeOS theme.

## Why not systemd-boot

- With Secure Boot on, systemd-boot needs either our own signing key (enrolled by the user through MOK) or UKIs signed by a key the firmware trusts. Neither works on stock Windows PCs in v1.
- systemd-boot can only load binaries from its own ESP. Chainloading Windows on a *second* disk, which is common on desktops, doesn't work.
- Fedora signs GRUB, not systemd-boot.

## Details

- Windows entry: os-prober, plus a fallback static `chainloader /EFI/Microsoft/Boot/bootmgfw.efi` entry that searches by ESP UUID.
- Default entry and timeout are set in Settings → Boot (written to `/etc/default/grub`, then `grub2-mkconfig`). The installer sets ZeeOS as default with a 5-second timeout.
- The installer adds its own NVRAM entry (`ZeeOS`) and **never** changes `BootOrder` entries for Windows Boot Manager other than putting ZeeOS first, which the user can opt out of.
- Theme lives in `/branding/grub/`. It must stay readable at 800×600 and in the firmware's text mode.
