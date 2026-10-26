# Architecture Decision Records

| ADR | Title | Status |
|---|---|---|
| [0001](0001-base-distro.md) | Base distribution: Fedora | Accepted |
| [0002](0002-build-tool.md) | Build tool: kiwi-ng | Accepted |
| [0003](0003-installer.md) | Installer: Calamares | Accepted |
| [0004](0004-bootloader.md) | Bootloader: GRUB 2 via signed shim | Accepted |
| [0005](0005-desktop-route.md) | Desktop: Plasma 6 / KWin (v1) | Accepted |
| [0006](0006-licensing.md) | Licensing: GPL-3.0+, CC-BY-SA-4.0, OFL; name/logo reserved | Accepted |
| [0007](0007-release-signing.md) | Release signing: minisign | Accepted |
| [0008](0008-package-pinning.md) | Package pinning: per-arch closure lock + GHCR closure repo | Accepted |
| [0009](0009-english-only-language-scope.md) | Language scope: English only (Arabic/RTL requirement dropped) | Proposed |
| [0011](0011-installer-package-wayland-only.md) | Installer package: ZeeOS rebuild of Fedora's Calamares without setxkbmap (supersedes ADR-0003's package part) | Proposed |
| [0012](0012-hardening-defaults.md) | Hardening defaults: firewalld, no sshd, security-only dnf5 automatic, SELinux enforcing | Accepted |

New ADRs: copy `template.md`, use the next number, and open a PR labeled `decision`. An ADR becomes **Accepted** when its PR merges after cross-review (Claude/Codex) with all review threads resolved; no separate owner approval is needed. The owner can still reject one by closing the PR or superseding the ADR.
