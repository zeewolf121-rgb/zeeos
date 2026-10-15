# ADR-0002: Image build tool

- Status: **Proposed** (depends on ADR-0001)
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

## Decision (proposed)

**kiwi-ng** builds the ISOs, using one shared description in `build/common/` plus overlays in `build/arch/<arch>/`. kiwi-ng also builds the raw disk image that `vm-integrator` wraps into the `.utm` bundle in Phase 5, so we only have one build tool.

## Consequences

- `make iso` runs kiwi-ng in a pinned Fedora container. Building needs privileges (loop devices), so CI runs it on full VMs (GitHub-hosted runners), not unprivileged containers.
- mkosi stays a possible choice later for the v2 image-based/atomic variant.
