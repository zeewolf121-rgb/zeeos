# ADR-0001: Base distribution

- Status: **Accepted** (owner, 2026-10-16, Phase 0 decision D1)
- Date: 2026-10-16
- Deciders: owner; architect (Claude); reviewer (Codex)

## Context

ZeeOS needs a base that gives us, on **both** x86_64 and aarch64:
a Microsoft-signed shim, a signed GRUB and kernel, a current KDE Plasma 6 on Wayland, a supported live-ISO build tool, mandatory access control on by default, and automatic security updates.

## Options

| Criterion | Fedora (44 now, 45 on GA) | Debian 13 "trixie" |
|---|---|---|
| Signed shim x86_64 | Yes (MS UEFI CA) | Yes (MS UEFI CA) |
| Signed shim aarch64 | Yes, Fedora ships signed `shimaa64` | Yes, `shim-signed` arm64 |
| Plasma version | Latest 6.x, follows upstream within weeks | 6.3 for the whole release (~2 years) |
| Wayland-only Plasma | Already the default; X11 session removed from the KDE edition | X11 session still shipped; we would remove it |
| MAC by default | SELinux enforcing, targeted policy | AppArmor enabled |
| Live ISO tooling | kiwi-ng (used for Fedora's own live media), also livemedia-creator | live-build (official Debian live images) |
| Calamares | Packaged, but Fedora's own editions use Anaconda | First-class: it's Debian's live installer |
| Auto updates | `dnf5-plugin-automatic` | `unattended-upgrades` |
| Support window | ~13 months per release, so we rebase twice a year | ~3 years + LTS |
| Kernel / hardware | Very recent, which helps new laptops and T2 Macs | Older. Backports kernel available |

## Decision

**Fedora 44** (pinned; Fedora 45 is in Beta as of 2026-10-16).

**Upgrade policy:** ZeeOS moves to Fedora N+1 **one month after N+1's GA**. From N+1 Beta onward CI also builds against N+1 so the rebase PR is ready; the pin changes in one PR that updates this ADR, `build/` and the build container together.

Why:
1. The desktop is the product. Fedora keeps us on current Plasma 6 / KWin. With Debian we would be stuck on Plasma 6.3 until 2027, and the Plasma 6.4+ features we want (better tiling, HDR, per-screen virtual desktops) would be missing.
2. Fedora's KDE edition is already Wayland-only and SELinux-enforcing, which matches two hard constraints with no extra work.
3. Signed shim, GRUB and kernel exist on both architectures, and Fedora's aarch64 support is first-class (Fedora also works with Asahi, which matters for Phase 7).
4. kiwi-ng builds Fedora's own live media, so we reuse a maintained path instead of writing our own.

## Consequences

- **Rebase twice a year**, one month after each Fedora GA (next: Fedora 45). CI has to build against `fedora:N+1` from Beta onward. This is the main cost compared with Debian.
- The installer choice (ADR-0003) has to deal with Calamares not being Fedora's default installer.
- AppArmor in the brief becomes SELinux. Custom services need SELinux policy modules, which `security-hardener` owns.

## What would flip this decision

Choose **Debian 13** instead if the owner cares more about long support windows and a lighter maintenance load than about Plasma freshness, or if the Phase 1 spike finds that Calamares on Fedora can't pass `install-test.yml`.
