# ADR-0012: Hardening defaults: firewalld, no sshd, security-only dnf5 automatic, SELinux enforcing

- Status: **Accepted** (owner, delegated to the orchestrator, 2026-10-26)
- Date: 2026-10-26
- Deciders: owner; architect (Claude); reviewer (Codex)
- Refs: #270 (P5-1), docs/phases/phase-5.md. Implemented by P5-2 (`security/overlay/`, check unit) and P5-3 (image wiring)

## Context

Phase 5 calls this ADR "ADR-0009", but that number went to the language scope ADR and 0010 went to the closed PR #214. This is the next free number, 0012. The phase plan now uses 0012.

Phase 5 rules (docs/phases/phase-5.md): Fedora defaults first, drop-in files over them, no custom daemons. Hardening files live in `security/overlay/` and are copied as-is onto the image root. The guest check prints `ZEEOS_HARDENING_OK selinux=enforcing firewall=<firewalld|nftables> inbound=deny sshd=<off|keyonly> autoupdate=<on|live-off>`.

What the image has today (both `build/arch/<arch>/packages.lock`, Fedora 44):

- `fedora-release-identity-basic`, not the Workstation or KDE identity. So firewalld's default zone would be `public`, not `FedoraWorkstation`. `public` allows inbound `ssh`, `mdns` and `dhcpv6-client`.
- `selinux-policy-targeted`. Fedora's `/etc/selinux/config` ships `SELINUX=enforcing`.
- `mokutil`, `avahi` and `nss-mdns` (printer discovery and `.local` names).
- No `firewalld`, no `nftables`, no `openssh-server`, no dnf5 automatic plugin. P5-3 adds packages.

The ISO is one image for two roles. The live session runs from it, and Calamares `unpackfs` copies the same root to disk for the installed system. So a setting that only applies to the live session can't just be baked into the root, because the installed system would get it too. The existing live-only units in `desktop/live/overlay/` already solve this with `ConditionKernelCommandLine=rd.live.image`.

Boot chain: none of this touches it, on either architecture. Shim, GRUB and the kernel are still Fedora's signed files (ADR-0004, ADR-0007). Everything here is userland config in `/etc` and `/usr/lib`. SELinux mode is not set on the kernel command line, so GRUB config doesn't change.

## Options

**1. Firewall front end**

- **a. firewalld (nftables backend)**: Fedora's default on every edition. NetworkManager assigns zones to connections. Plasma's firewall settings page (`plasma-firewall`) has a firewalld backend. Users and docs everywhere expect `firewall-cmd`. Zone files in `/etc/firewalld/zones/` override those in `/usr/lib/firewalld/zones/` by name, which is a real drop-in.
- **b. plain `nftables.service` ruleset**: smaller, no daemon. But there's no GUI, no per-connection zones, and every user change means editing a ruleset file by hand. It also goes against "Fedora defaults first".

**2. Default zone contents**

- **a. Keep Fedora's `public`**: allows `ssh` inbound, though no sshd is installed (see 3).
- **b. Override `public` with a ZeeOS file**: same name, so the default zone setting and NetworkManager's default stay as they are. ZeeOS chooses the allowed services.
- **c. New `zeeos` zone plus a `DefaultZone=` change**: firewalld has no `firewalld.conf` drop-in directory, so this means editing or replacing Fedora's whole `firewalld.conf`.

**3. sshd**

- **a. Not installed**: nothing listens. Users who want it run `dnf install openssh-server`.
- **b. Installed, disabled**: what Fedora Workstation does. More packages and a CVE surface that most desktop users never use.
- **c. Installed, enabled**: an inbound service on a desktop, which goes against inbound deny.

**4. Automatic updates**

- **a. `dnf5-automatic.timer`, security only, apply, never reboot.**
- **b. Download only, user applies**: safer for running sessions, but most users never apply them.
- **c. All updates, apply**: more change than a silent unattended job should make.
- **d. Plasma Discover's offline updates only**: needs PackageKit. It isn't a policy we can check from the serial console.

**5. Live-off mechanism**

- **a. Mask the timer in the image**: Calamares copies the mask to disk, so the installed system would need an unmask step in the installer.
- **b. Condition drop-in** `ConditionKernelCommandLine=!rd.live.image` on the timer: the same root works for both, with no installer change.

## Decision

1. **Firewall: firewalld with its nftables backend** (1a). Fedora's default `firewalld.conf` stays unchanged (`FirewallBackend=nftables`, `DefaultZone=public`). The marker reports `firewall=firewalld`.

2. **Default zone: override `public`** (2b) with `security/overlay/etc/firewalld/zones/public.xml`:
   - target `default` (firewalld rejects anything not allowed), no ports, no forward ports, no masquerade, no rich rules;
   - allowed services: **`dhcpv6-client`** (IPv6 addresses on many networks) and **`mdns`** (avahi/nss-mdns: `.local` names and printer discovery; multicast replies don't count as established traffic, so mDNS needs an open port to work at all);
   - **`ssh` is removed** (no sshd, see 3). Nothing else is opened: no KDE Connect, no Samba, no cockpit. Users open those on purpose, with `firewall-cmd` or Plasma's firewall page.

   That is what `inbound=deny` means in the marker: firewalld is running, the default zone is `public`, its target is `default`, there are no open ports, and its services are a subset of `{dhcpv6-client, mdns}`.

3. **sshd: not installed** (3a). `openssh-server` stays out of `build/common/packages.xml` (the `openssh-clients` package may stay). The overlay still ships the key-only drop-in, **`/etc/ssh/sshd_config.d/40-zeeos-keyonly.conf`**, with:

   ```
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PermitRootLogin prohibit-password
   ```

   So a user who installs `openssh-server` later gets key-only login. sshd reads `sshd_config.d/*.conf` in order and the first value wins. Fedora's own `50-redhat.conf` sorts after `40-`. They also need `firewall-cmd --permanent --add-service=ssh`, which is documented and not done for them. Marker: `sshd=off` when `sshd.service` isn't active; `sshd=keyonly` when it's active and `sshd -T` reports `passwordauthentication no` and `kbdinteractiveauthentication no`. Anything else is `ZEEOS_HARDENING_FAIL sshd: …`.

4. **Auto-update: dnf5 automatic, security only, apply, no auto-reboot** (4a). `security/overlay/etc/dnf/automatic.conf` sets only the keys ZeeOS changes. dnf5 automatic reads the package defaults from `/usr/share/dnf5/dnf5-plugins/automatic.conf` first, so this file works as an override over them:

   ```
   [commands]
   upgrade_type = security
   download_updates = yes
   apply_updates = yes
   reboot = never
   ```

   Updates take effect at the next normal reboot. ZeeOS never reboots a desktop on its own. P5-3 adds the plugin package and enables the timer in `build/common/config.sh` (`systemctl enable`; overlay files are copied after package scriptlets run, so presets in the overlay would not be applied). P5-3 checks the package name, the timer name and the defaults path with `dnf repoquery` / `dnf repoquery -l` in the build container, the package probably being `dnf5-plugin-automatic` and the timer `dnf5-automatic.timer`. If any of those differ, P5-2/P5-3 use the real names and note it on the PR. That doesn't need a new ADR. Package updates still come from Fedora's signed repos (ADR-0008 pins the image build, not the installed system's later updates).

5. **SELinux: enforcing, checked, not configured.** Fedora's `/etc/selinux/config` already says `SELINUX=enforcing` with `SELINUXTYPE=targeted`. The overlay doesn't ship that file. The check fails unless all three hold: `getenforce` prints `Enforcing`, `/etc/selinux/config` has `SELINUX=enforcing`, and `/proc/cmdline` has no `selinux=0` or `enforcing=0`. That holds on the live session too. If the live boot can't run enforcing, that's a `ZEEOS_HARDENING_FAIL selinux: …` and a `decision` issue, never a quiet switch to permissive.

6. **Live-off: a condition drop-in, not a mask** (5b). `security/overlay/usr/lib/systemd/system/dnf5-automatic.timer.d/50-zeeos-live-off.conf`:

   ```
   [Unit]
   ConditionKernelCommandLine=!rd.live.image
   ```

   This is the same `rd.live.image` test the live units in `desktop/live/overlay/` use. The timer is enabled in the image, skipped in the live session and runs on the installed system Calamares copies, with no installer step. Marker: `autoupdate=live-off` when `rd.live.image` is on the command line and the timer is inactive. `autoupdate=on` when it isn't, and the timer is enabled and active. The live session keeps SELinux enforcing and the firewall on (items 2 and 5 hold in both).

7. The same files apply to both architectures and to the UTM `oem` disk (P5-5). It has no `rd.live.image`, so it gets `autoupdate=on`. Nothing goes in `build/arch/<arch>/`.

## Consequences

- P5-2 writes: `security/overlay/etc/firewalld/zones/public.xml`, `security/overlay/etc/ssh/sshd_config.d/40-zeeos-keyonly.conf`, `security/overlay/etc/dnf/automatic.conf`, the timer drop-in above, and the check unit and script with the rules from items 2–6. Each file needs a REUSE entry.
- P5-3 adds `firewalld` and the dnf5 automatic plugin to `build/common/packages.xml` (`mokutil` is already in the locks), doesn't add `openssh-server`, enables the timer, refreshes both locks, and copies the overlay. The phase plan's "mask the timer in the live session only" becomes the condition drop-in, so P5-3 masks nothing.
- The default image has no inbound service except mDNS and DHCPv6 client. Nothing to enable for SSH unless the user installs it.
- A user running the live session for a long time gets no security updates. That's expected: the live medium is read-only and replaced by each release.
- A security update may wait for the next reboot to take effect (kernel, glibc, Plasma). That's the trade-off for never rebooting on its own. A notification that a reboot is pending is out of scope for v1.
- Overriding `public.xml` means a future Fedora change to `public` (a new service) won't reach ZeeOS. That's intended: ZeeOS owns its inbound list.

## What would flip this decision

- Fedora drops firewalld as its default or Plasma drops its firewalld backend → revisit 1 (plain nftables).
- The owner wants headless or remote-first use (for example on the UTM bundle) → install `openssh-server`, disabled, with the key-only drop-in already in place (3b).
- Security-only updates break installed systems in CI or in user reports, or Fedora's `updateinfo` security metadata turns out to be unreliable → download-only (4b).
- The live session can't boot SELinux enforcing on kiwi's live root → a new ADR, not a silent permissive mode.
- dnf5 automatic gains a reboot-pending notification for Plasma → add it, still with `reboot = never`.
