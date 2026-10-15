# ADR-0003: Installer

- Status: **Proposed** (needs owner approval, labeled `decision`, `installer-disk`)
- Date: 2026-10-16

## Context

The brief prefers Calamares, or Anaconda if the base is Fedora, with a written justification. The installer has to provide: erase disk, a **guided resize "install alongside"**, manual partitioning, LUKS2, our own pre-flight safety checks (BitLocker, Fast Startup/dirty NTFS, ESP backup), a full summary/confirmation screen, and ZeeOS branding.

## Options

| Need | Calamares 3.3 | Anaconda (Web UI) |
|---|---|---|
| Guided "install alongside" with a resize slider | Built in (`partition` module, "Install alongside") | "Use free space" / "reclaim space" only. No guided resize-alongside flow |
| Custom pre-flight checks | Python `job` modules + QML `view` modules, easy to add | Python addons, more work, tied to Fedora's release cycle |
| Branding | Full QML slideshow + branding descriptor | Limited |
| Unattended mode for CI | Yes, via preseeded settings / `calamares -d` with config overrides | Kickstart (very strong) |
| Fedora integration | Packaged, community-maintained | Native, best tested |
| RTL / Arabic | Qt, RTL supported | Supported |

## Decision (proposed)

**Calamares**, even though the base is Fedora. Anaconda's Web UI has no guided resize-alongside flow, and that flow is a core v1 requirement. Calamares also lets us add the BitLocker and Fast Startup checks as small, separately testable modules.

Custom modules (all in `/installer/modules/`, all labeled `installer-disk`):

| Module | Type | Job |
|---|---|---|
| `zee-preflight` | view + job | Find Windows/macOS/Linux installs. **Block** resizing a BitLocker volume (`-FVE-FS-` signature) and show how to suspend BitLocker. **Block** resizing dirty or hibernated NTFS (`ntfsfix --no-action`, `hiberfil.sys` check) and explain how to turn off Fast Startup. |
| `zee-espbackup` | job | Copy the ESP's contents into a tarball on the target root and record checksums **before** any bootloader write. Never format an existing ESP. |
| `zee-summary` | view | Mandatory "Do you have a backup?" checkbox plus a per-disk list of every change. The Install button stays disabled until the box is checked. |
| `zee-bootmenu` | job | GRUB theme, os-prober entry for Windows Boot Manager, configurable default and timeout. Never touch `\EFI\Microsoft\`. |

## Consequences

- We own the Calamares integration on Fedora. `install-test.yml` is the safety net and has to cover all three install paths before Phase 4 closes.
- Fallback if Calamares on Fedora is unworkable: switch to Debian (ADR-0001) rather than to Anaconda, because the resize-alongside requirement is what drives this choice.
