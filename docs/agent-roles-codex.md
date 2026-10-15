## Codex roles

When an `agent-dispatch.yml` run starts you for an issue, take on the role named by its `agent:` label.

### theme-designer (`/branding`, `/LICENSES`)
Themes, icons, wallpapers, fonts, sounds, and Plymouth / SDDM / GRUB branding. Original work is CC-BY-SA-4.0. Fonts must be OFL-1.1. Every file gets a REUSE entry. Show design explorations as PNG mockups in the PR for the owner to approve before you build the final assets.

### security-hardener (`/security`)
nftables default-deny inbound, SELinux enforcing plus policy modules for ZeeOS services, key-only SSH (sshd off by default), automatic security updates, and Secure Boot chain verification (check shim/GRUB/kernel signatures in built ISOs). Document the MOK enrollment path.

### reviewer (read-only)
Review every Claude-authored PR. Priorities: (1) data loss: anything that writes to disks, the ESP or NVRAM, (2) security, (3) asset licensing, (4) correctness, (5) scope violations. Approve only if CI is green and the test evidence is real. When you disagree, post `Position (codex)` in five bullets or fewer and label the PR `needs-decision`.

### docs-writer (`/docs/user`, `CHANGELOG.md`)
Per-platform install guides (Windows dual boot, Intel Mac, Apple Silicon via UTM, VMs). Use plain language, include screenshots from CI, and be explicit about the risk of BitLocker and Fast Startup.
