# ADR-0002: Image build tool

- Status: **Accepted** (owner, 2026-10-16, Phase 0 decision D2)
- Date: 2026-10-16

## Context

We need hybrid UEFI ISOs (and an optional BIOS path on x86_64) for two architectures, built from one description, inside a container, from a clean checkout.

## Options

| Tool | Live hybrid ISO | Fedora | Both archs | Notes |
|---|---|---|---|---|
| **kiwi-ng** | Yes (`iso` type, isohybrid, shim + signed GRUB) | Builds Fedora's own live media | Yes | Declarative XML/YAML profiles. Can also output a disk image for the UTM bundle |
| mkosi | No live ISO output (makes disk/UKI images) | Yes | Yes | Great for disk images, wrong shape for a live installer ISO |
| livemedia-creator (lorax) | Yes | Legacy Fedora path | Yes | Needs a full VM or anaconda in the build, slower and harder to containerize |
| live-build | Yes | Debian only | Yes | Use this if ADR-0001 flips to Debian |

## Decision

**kiwi-ng** builds the ISOs, using one shared description in `build/common/` plus overlays in `build/arch/<arch>/`. kiwi-ng also builds the raw disk image that `vm-integrator` wraps into the `.utm` bundle in Phase 5, so we only have one build tool.

## Why not mkosi

The brief named mkosi as the preferred tool, so this needs saying explicitly:

1. **No live ISO output.** mkosi produces disk images, UKIs, ESPs, directories and archives, not a bootable hybrid ISO9660 live medium. We would have to script dracut `dmsquash-live`, the squashfs, the El Torito EFI image, `xorriso` and isohybrid ourselves: custom code on the most fragile path we have.
2. **Secure Boot on stock PCs.** kiwi-ng's `iso` type already wires Fedora's Microsoft-signed shim and signed GRUB into the ISO. mkosi's boot path centres on systemd-boot + UKIs, which ADR-0004 rules out for v1.
3. **Fedora uses kiwi-ng** for its own live media, so the path we depend on is maintained and tested by the base distro.
4. **One tool for everything.** kiwi-ng also builds the raw disk image for the UTM bundle (Phase 5). mkosi would only cover that half.

mkosi is the right tool for an image-based/atomic v2 (UKI, systemd-boot, sysext), so we revisit it there.

## Consequences

- `make iso` runs kiwi-ng in a pinned Fedora container. Building needs privileges (loop devices), so CI runs it on full VMs (GitHub-hosted runners), not unprivileged containers.
- mkosi stays a possible choice later for the v2 image-based/atomic variant.
