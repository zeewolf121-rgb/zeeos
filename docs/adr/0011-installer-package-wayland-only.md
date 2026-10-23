# ADR-0011: Installer package: ZeeOS rebuild of Fedora's Calamares without setxkbmap

- Status: Proposed
- Date: 2026-10-23
- Deciders: owner; architect (Claude); reviewer (Codex)
- Supersedes: **only the package part of ADR-0003** ("Calamares 3.3 from Fedora", "Fedora integration: packaged"). ADR-0003's choice of Calamares, its custom module list and its disk-safety rules stay as they are. ADR-0003 itself is not edited.
- Amends: ADR-0008, only for how ZeeOS-built RPMs are verified (Decision 5). Fedora RPMs keep `package_gpgcheck="true"`.
- Refs: #210 (owner ruling), #175 / PR #211 and #216 (P4-1), PR #214 (now moot, see below)

## Context

Fedora 44's `calamares-3.3.14-5.fc44` has a hard `Requires: setxkbmap`, which is an X11-only tool. Hard rule 3 says Wayland only, with no X11-only components. On 2026-10-23 the owner ruled **no** on #210: setxkbmap is not allowed, not even as a forced dependency of Fedora's calamares, and rule 3 stays as written. PR #214 proposed a narrow exception, and the ruling makes it moot. #214 has since been renumbered to 0010, so this ADR uses 0011.

The whole Phase 4 installer chain waits on this: #175 (P4-1, PR #211) → #176 (P4-2) → #178, #179, #181. Today is the project deadline, so the option that unblocks fastest wins, as long as it keeps rule 5 (reproducible `make iso` from a clean checkout) and ADR-0008 (closure lock and GHCR closure repo). The signed boot chain (ADR-0004) must not change on either arch.

### Evidence

All commands ran on 2026-10-23 in `registry.fedoraproject.org/fedora:44` under podman on the owner's Mac. The native container is aarch64 and runs dnf5 5.4.6.0. Where x86_64 is marked, the container is `--platform linux/amd64`. Output is trimmed to the relevant lines.

**E1. Calamares' Requires, and who else needs setxkbmap.**

```console
$ dnf -q repoquery --requires calamares        # 3.3.14-5.fc44
... console-setup, efibootmgr, grub2, grub2-efi, kdesu, ntfsprogs, os-prober, setxkbmap, upower ...
$ dnf -q repoquery --whatrequires setxkbmap    # same set with --forcearch x86_64
bicon  calamares  ibus-panel  x2goserver  xorg-x11-xinit
$ dnf -q repoquery --whatrequires xorg-x11-xinit
... plasma-login-manager ... sddm-0:0.21.0-13.fc44 ... (gdm, lightdm, xrdp, ...)
$ dnf -q repoquery --latest-limit 1 --requires sddm | grep xinit
xorg-x11-xinit
```

**E2. main already ships setxkbmap without Calamares.** `build/arch/{x86_64,aarch64}/packages.lock` on main (668a3ea) contains `setxkbmap 0:1.3.4-7.fc44`, `xorg-x11-xinit 0:1.4.3-4.fc44` and `xmodmap` on both arches. Calamares isn't in the lock yet. The chain is `sddm` (in `build/common/packages.xml`, display manager per ADR-0005) → `xorg-x11-xinit` → `setxkbmap`. `plasma-login-manager` has the same chain, so swapping the display manager doesn't help.

**E3. The ruling can't be met with dnf excludes alone.** The full kiwi set is `build/common/packages.xml` plus the aarch64 `config.xml` names.

```console
$ dnf install --assumeno --exclude=setxkbmap calamares
Problem: package calamares-3.3.14-5.fc44 requires setxkbmap, but none of the providers can be installed
$ dnf install --assumeno --installroot=/tmp/kset2 ... --exclude=fedora-logos,fedora-logos-classic,setxkbmap \
    <full kiwi set> <rebuilt calamares, calamares-libs>
Problem 1: package sddm-0.21.0-13.fc44 requires xorg-x11-xinit, but none of the providers can be installed
  - package xorg-x11-xinit-1.4.3-4.fc44 requires setxkbmap ...
  - package setxkbmap-1.3.4-7.fc44 is filtered out by exclude filtering
```

So dropping only Calamares' Requires makes Calamares compliant, but the ISO **still ships setxkbmap through sddm**. See scope question S below.

**E4. Calamares' Requires is a one-line spec change.** I fetched the SRPM with `dnf download --source calamares` (`calamares-3.3.14-5.fc44.src.rpm`). In `calamares.spec`, line 117 `Requires: setxkbmap` sits **outside** every `%ifarch`, so it applies to both arches. The `grub2-efi-x64` (x86_64) and `grub2-efi` (other arches) Requires are inside `%ifarch` and stay untouched.

```console
$ diff calamares.spec calamares-zeeos.spec
< Release:        5%{?dist}
> Release:        5.zeeos1%{?dist}
< Requires:       setxkbmap
$ dnf builddep -y calamares-zeeos.spec && rpmbuild -bb calamares-zeeos.spec   # aarch64, native
builddep rc=0 / build rc=0 / real 1m47s
$ rpm -qpR calamares-3.3.14-5.zeeos1.fc44.aarch64.rpm calamares-libs-...rpm | grep -c -i -E 'setxkbmap|xorg|xinit'
0
```

**Evidence scope:** the Calamares rebuild, the sddm rebuild (E6) and the full-set resolution (E6) ran natively on aarch64. The x86_64 run is reported in the PR, with the result it actually got. The argument carries across arches because `Requires: setxkbmap` sits outside `%ifarch` and the sddm `x11` bcond isn't arch-conditional, but x86_64 remains unverified until F2 and F3 build it.

**E5. Without setxkbmap, the keyboard module still sets the live keymap on Wayland/KWin.** Source: `calamares-3.3.14/src/modules/keyboard/Config.cpp`.

- setxkbmap is called in exactly three places, all in `keyboard/Config.cpp`, and nowhere else in the tree (`grep -rln setxkbmap` over .cpp/.h/.py/.conf/.qml/.yaml):
  - `xkbmap_query_grp_option()`, which runs `setxkbmap -query`;
  - `applyXkb()`, which runs `setxkbmap <args>`;
  - `getCurrentKeyboardLayoutXkb()`, which runs `setxkbmap -print`.
- `getCurrentKeyboardLayoutXkb()` only runs when `useLocale1` is false. `useLocale1` defaults to `!isX11`, where `isX11 = platformName() == "xcb"`. On Wayland, detection therefore reads `org.freedesktop.locale1` `X11Layout`/`X11Variant`/`X11Model` over the system bus.
- `applyXkb()` **always** runs: `m_configureXkb = true` in `Config.h`, and no config key turns it off. Without the binary, `QProcess::execute` cannot start the process. Qt documents a return value of -2 in that case, and Calamares ignores the return value, so this is a no-op. Even with setxkbmap installed, it would only change Xwayland's keymap, never KWin's.
- `applyLocale1()` calls `org.freedesktop.locale1.SetX11Keyboard(layout, model, variant, option, convert=true, …)` on the system bus. This sets systemd-localed's keymap and the vconsole keymap.
- `configure: kwin: true` is the alternative. `applyKWin()` rewrites keys that already exist in an existing `kxkbrc`, then sends the `org.kde.keyboard /Layouts reloadConfig` signal on Calamares' session bus.

KWin side, from `dnf download --source kwin` (6.7.5, the version in the lock):

```text
src/main_wayland.cpp:381  QCommandLineOption locale1Option("locale1", "Extract locale information from locale1 rather than the user's configuration")
src/main_wayland.cpp:506  a.setFollowLocale1(a.config()->group("Wayland").readEntry("FollowLocale1", false));   // a.config() = kwinrc (main.cpp:84)
src/xkb.cpp:496           QDBusConnection::systemBus().connect("org.freedesktop.locale1", ..., "PropertiesChanged", this, SLOT(reconfigure()));
```

KWin follows locale1 **live**: it reconnects on every `PropertiesChanged`. This happens when it runs with `--locale1` **or** when `kwinrc` has `[Wayland] FollowLocale1=true`. Fedora's `plasma-kwin_wayland.service` runs `kwin_wayland_wrapper --xwayland` with no `--locale1`, so the live session needs the kwinrc key. That's a config file, not a unit override.

The live path is therefore: Calamares `useLocale1: true` → localed → KWin `reconfigure()`. setxkbmap isn't involved anywhere.

**Runtime-unverified:**
- Calamares runs via `kdesu /usr/bin/calamares` (Fedora patch `calamares-3.3.3-kdesu.patch`). Nobody has yet observed whether Qt picks `wayland` or `xcb` (through Xwayland) under kdesu as root. P4-2 sets `useLocale1: true` explicitly so the outcome doesn't depend on that.
- `kwin_wayland` wouldn't exec in the container ("Operation not permitted"). The KWin behaviour above comes from source, not from a run.

**E6. sddm has an upstream switch for exactly this.** `sddm.spec` (from `dnf download --source sddm`, 0.21.0-13.fc44, the same NEVRA as the lock):

```text
2:   %bcond x11 %[%{undefined rhel} || 0%{?rhel} < 10]
104: %if %{with x11}
105: Requires: xorg-x11-xinit
```

`--without x11` is the build Fedora/EPEL uses for RHEL 10. It drops `Requires: xorg-x11-xinit`, the `sddm-x11` subpackage and `x11.conf`.

```console
$ rpmbuild -bb --without x11 sddm.spec       # Release 13.zeeos1, aarch64: build rc=0, real 0m36s
$ rpm -qpR sddm-0.21.0-13.zeeos1.fc44.aarch64.rpm   # no xorg-x11-xinit
$ dnf install --assumeno --installroot=/tmp/kset4 ... --exclude=fedora-logos,fedora-logos-classic,setxkbmap,xorg-x11-xinit \
    <full aarch64 kiwi set> <rebuilt sddm> <rebuilt calamares, calamares-libs>
Transaction Summary: Installing: 854 packages      # resolves; no setxkbmap, no xorg-x11-xinit, no xmodmap
 calamares 3.3.14-5.zeeos1.fc44 / sddm 0.21.0-13.zeeos1.fc44 / shim-aa64 16.1-7 / grub2-efi-aa64 1:2.12-66.fc44 (Fedora's)
 still present: xkbcomp, xprop, xrdb   (Xwayland and plasma-workspace; not covered by the #210 ruling)
```

**E7. Anaconda WebUI.**

```console
$ dnf -q repoquery --latest-limit 1 --requires anaconda-webui      # anaconda-webui-68-1.fc44
(firefox if fedora-release-workstation), anaconda-core >= 42.5, cockpit-bridge, cockpit-networkmanager, cockpit-storaged, cockpit-ws, python3-bugzilla, system-logos
$ dnf -q repoquery --latest-limit 1 --requires anaconda-live       # anaconda-live-44.30-2.fc44
anaconda-webui, python3-dbus-next, zenity, ...
$ dnf install --assumeno --installroot=/tmp/r --setopt=install_weak_deps=False anaconda-webui anaconda-live
Installing: 414 packages   X11 names: libX11 libX11-common libX11-xcb   (no setxkbmap, no xorg-x11-*)
$ ... firefox anaconda-webui anaconda-live
Installing: 449 packages   adds libX* client libs and xprop; no setxkbmap, no xorg-x11-*
```

`/usr/libexec/anaconda/webui-desktop` launches a browser: `webui_web_engine` from anaconda.conf, **default `firefox`**. Firefox isn't in either lock today. The storage UI's reclaim dialog has a per-device "shrink to $0" action (`index.js.gz`). That's a manual shrink, not ADR-0003's guided "install alongside" slider. Anaconda alone doesn't fix E2: sddm still pulls setxkbmap.

**E8. For comparison**, the same empty-installroot resolution of stock `calamares` brings in `setxkbmap` and `xprop` (418 packages).

## Options

| | 1. Rebuild Calamares (spec-only) | 1+S. Also rebuild sddm `--without x11` | 2. Anaconda WebUI | 3a. Stub `Provides: setxkbmap` / `--nodeps` / kiwi `<ignore>` | 3b. Debian (ADR-0003's fallback) |
|---|---|---|---|---|---|
| setxkbmap in Calamares' deps | No (E4) | No | n/a | Hidden, not removed | n/a |
| setxkbmap in the ISO | **Yes, through sddm** (E3) | **No** (E6, verified on aarch64; x86_64 not run, see Evidence scope) | **Yes, through sddm** (E2) | Hidden | Debian's own question, not checked |
| Live keymap on Wayland | Yes: locale1 → KWin `FollowLocale1` (E5; runtime check in P4-2) | same | Yes (Anaconda uses localed) | same as 1 | n/a |
| Dual-boot modules | Unchanged: zee-preflight and zee-espbackup are merged; zee-summary and zee-bootmenu as planned | Unchanged | **Rewrite** all four as Anaconda addons or kickstart `%pre`. WebUI has no addon UI for zee-summary's checkbox | Unchanged | Rebuild the whole image stack |
| Guided alongside resize | Yes | Yes | No (manual shrink only, E7) | Yes | Yes |
| Unattended preset / markers (#180, #181, PR #193) | Unchanged | Unchanged | Redesign around kickstart | Unchanged | Redesign |
| New pipeline | ZeeOS RPM build step + second repo in the closure | same step, 2 packages | Firefox (or another browser) added to the image | stub package | everything |
| Effort | Small. Spec delta is 2 lines, build takes ~2 min per arch, plus the build step and lock wiring | Small + about 1 hour (same pipeline) | Large (days) | Small | Very large |
| Risk | Low. Sources unchanged, Fedora's own patches kept | Low: a Fedora-supported bcond. One caveat on installed-system updates (Consequences) | High on the deadline | **Not acceptable**: misstates dependencies and breaks if Fedora's setxkbmap is pulled anyway; `--nodeps` leaves a broken rpmdb (E3 shows exclude fails) | Not feasible today |

## Decision (proposed)

**Option 1.** Items 1, 2, 4, 5 and 6 below are the decision. Two questions remain **pending owner input** and are **not** decided by merging this ADR:

- scope question S, in item 3;
- the installed-system choice in item 6.

Until the owner answers, F3 stays blocked.

1. ZeeOS rebuilds Fedora's own `calamares` SRPM, pinned by NEVRA and sha256. The only change is a spec delta: drop `Requires: setxkbmap` and set Release `5.zeeos1`. There are no source patches, and Fedora's `default-settings` and `kdesu` patches stay. This is a rebuild, not a fork, and it keeps phase-4's "no Calamares fork, no compiled modules" rule. **No** C++ patch to `applyXkb()`: E5 shows it's a harmless no-op.
2. **Keyboard on Wayland (P4-2 config):**
   - `keyboard.conf` sets `useLocale1: true` explicitly and `configure: kwin: false`.
   - The live session ships `kwinrc` with `[Wayland] FollowLocale1=true`, for the live user only (F4a).
   - The test harness checks the live keymap after the keyboard page through KWin, not through `setxkbmap -query`.
3. **Scope question S (pending owner input).** Does the ruling cover the whole ISO, or only Calamares' Requires? Architect recommendation: **the whole ISO.**
   - Also rebuild Fedora's `sddm` SRPM `--without x11`, the bcond Fedora itself uses for RHEL 10 (E6). Release becomes `13.zeeos1`.
   - With that, the ISO has neither setxkbmap nor xorg-x11-xinit (E6). It doesn't block the installer chain and can land right after P4-1.
   - If the owner picks "Calamares only", skip this step. The ISO then keeps setxkbmap through sddm, as main does today.
4. **Build pipeline (reproducible, rule 5).** image-builder owns this.
   - **Inputs.** `build/rpms/<name>/` holds:
     - `source.lock`: the Fedora SRPM NEVRA and sha256;
     - the spec delta, as a patch or a scripted edit;
     - `rpmbuild` options (`--without x11` for sddm).
     
     Nothing there is arch-specific. If that changes, the difference goes in `build/arch/<arch>/` (rule 4).
   - **Build.**
     - `make rpms ARCH=<arch>` runs natively per arch inside the digest-pinned tools image (ADR-0008).
     - It fetches the SRPM by NEVRA from mirrors, falling back to Koji's signed copy, and checks the sha256. It installs BuildRequires and records them as `build/arch/<arch>/rpms-buildroot.lock` (`rpm -qa`), so the build environment is reviewable.
     - It runs `rpmbuild` with `SOURCE_DATE_EPOCH` taken from the SRPM changelog.
   - **Publishing.** The resulting binary RPMs and SRPMs go into the GHCR closure artifact, as a separate directory `zeeos/`. Their lines in `packages.lock` carry source `zeeos-rebuild`.
   - **`make iso` from a clean checkout.** It pulls them by digest like every other locked RPM and never rebuilds. `ZEEOS_CLOSURE_REBUILD=1` reruns `make rpms` and fails on an identity mismatch with the lock. It doesn't promise byte-identical RPMs.
   - **Refresh.** The daily refresh (ADR-0008) also watches the Fedora NEVRA of each rebuilt package. When Fedora ships a new calamares or sddm, the rolling PR rebuilds it with the same delta and fails if the delta no longer applies.
5. **Signing (no secrets in the repo, rule 6).**
   - `repos-pinned.xml` accepts only Fedora-signed RPMs (`package_gpgcheck="true"`, Fedora 44 key). ZeeOS RPMs therefore go in a **second kiwi repository** pointing at `zeeos/`.
   - **Interim (unblocks today):** that repo has `package_gpgcheck="false"`. `build-iso.sh` verifies every RPM in it against the lock's sha256 **before** kiwi runs, and fails closed. The bytes are already pinned by the GHCR digest in the lock header, which is the same trust root as `tools-image.lock`. This narrows ADR-0008's "gpgcheck on". The rule's aim was never to install unverified *Fedora* RPMs, and the Fedora repo keeps gpgcheck.
   - **Target, as a separate decision:** a ZeeOS RPM signing key, GPG, because minisign (ADR-0007) can't sign RPMs.
     - The private key lives in GitHub encrypted secrets, scoped to an environment.
     - The public key goes under `security/keys/` (security-hardener).
     - `rpmsign` signs during the publish job.
     - Then the second repo turns on `package_gpgcheck="true"`.

     Key custody is the owner's decision. This ADR doesn't decide it.
6. **Installed systems.**
   - Calamares and its subpackages are removed from the target as part of P4-2's live-only cleanup, so a later Fedora calamares can never pull setxkbmap back in.
   - If S is accepted, sddm stays on the target. Installed systems use stock Fedora repos (ADR-0008 point 5), so Fedora's next `sddm` build (`-14` sorts above `13.zeeos1`) would bring `xorg-x11-xinit` and setxkbmap back on update. v1 options:
     - (i) accept this and document it;
     - (ii) a ZeeOS update repo, a Phase 5+ question;
     - (iii) a dnf `excludepkgs`, which **is not recommended** because it silently stops sddm security updates.
     
     **Pending owner input.** The architect leans towards (i), but the owner should see the cost plainly: under (i), installed systems get setxkbmap and xorg-x11-xinit back as soon as Fedora ships the next sddm update. Only the ISO and a fresh install are setxkbmap-free.

### Signed boot chain, both arches

No change. The rebuilt packages are userspace only.
- `shim-x64`/`grub2-efi-x64` and `shim-aa64`/`grub2-efi-aa64` and `kernel` remain Fedora-signed RPMs from the gpg-checked Fedora repo. E6's resolution picked Fedora's `shim-aa64 16.1-7` and `grub2-efi-aa64 1:2.12-66.fc44`.
- Calamares' `grub2-efi-x64` / `grub2-efi` Requires are untouched (E4).
- What the installer writes to the ESP is still governed by ADR-0004 and P4-7 (zee-bootmenu).
- `make boot-test SECUREBOOT=on` stays the gate on both arches for the PR that first adds the rebuilt RPMs.

## Consequences

- **Phase 4 issues:**
  - #175 / PR #211 and #216 (P4-1; #216 carries the same #175 change with an empty PR body): Calamares comes from `zeeos/`, not Fedora's `calamares`. Add the build step, then regenerate the locks. The `Install ZeeOS` launcher keeps `kdesu /usr/bin/calamares`.
  - #176 (P4-2): adds `useLocale1: true`, the live `kwinrc` key, and removal of the calamares packages on the target.
  - #178, #179 and #181: no change beyond their existing dependency on #176.
  - #180 / PR #193: no change.
- **Phase-4 scope text:** "Calamares 3.3 from Fedora" now reads "Fedora's Calamares 3.3 sources, rebuilt by ZeeOS without the setxkbmap dependency (ADR-0011)". The rule against forks and compiled modules stays.
- **New pipeline to maintain:** two packages, rebuilt whenever Fedora updates them. Fedora calamares updates are rare. sddm updates are rare too, but they matter for security.
- **Redistribution:** we now distribute binaries we built ourselves. The SRPMs go into the closure artifact alongside them (ADR-0008's redistribution note; ADR-0006).
- **Remaining X11 client helpers** (`xkbcomp`, `xprop`, `xrdb`, through Xwayland and plasma-workspace) are outside the #210 ruling. If the owner wants rule 3 to cover them, that's a separate decision. They come with Xwayland, which this ADR doesn't change.

## Follow-up issues

| # | Title | Agent | Model | Arch | Deps | Flags |
|---|---|---|---|---|---|---|
| F1 | build: `make rpms`, rebuild Fedora's calamares SRPM without `Requires: setxkbmap` (`build/rpms/calamares/`, SRPM lock, buildroot lock, `zeeos/` dir in the closure, second kiwi repo with sha256 fail-closed check) | image-builder | claude | both | this ADR Accepted | `parallel-safe` |
| F2 | build: P4-1 uses the F1 calamares; refresh both locks; boot-test SB on, both arches (supersedes the Fedora-calamares part of PR #211 / #216) | image-builder | claude | both | F1 | — |
| F3 | build: rebuild sddm `--without x11` in the same pipeline; locks without setxkbmap/xorg-x11-xinit; boot-test SB on, both arches | image-builder | claude | both | F1, owner answer on S | `parallel-safe` with F2 after F1 |
| F4a | build: write `/home/liveuser/.config/kwinrc` `[Wayland] FollowLocale1=true` in `build/common/config.sh`, live user only (removed with liveuser's home on the target). Not `/etc/xdg/kwinrc`, because that file reaches installed systems | image-builder | claude | both | F2 | `parallel-safe` |
| F4b | installer: P4-2 keyboard config `useLocale1: true`, `configure.kwin: false`; remove calamares packages from the target; runtime check that the keymap changes in KWin under kdesu | installer-engineer | claude | both | F2, F4a (fold into #176) | `installer-disk` (via #176) |
| F5 | ci: refresh job watches rebuilt packages' Fedora NEVRAs and rebuilds them in the rolling PR (`needs-human`, workflow edit) | ci-engineer | claude | both | F1 | — |
| F6 | decision: ZeeOS RPM signing key (GPG; custody, environment, `security/keys/`); then switch the `zeeos/` repo to `package_gpgcheck="true"` | security-hardener | codex | both | owner | `decision`, not on the Phase 4 exit path |
| F7 | docs: once this is Accepted, add a "package part superseded by ADR-0011" note to ADR-0003's header and an amendment note to ADR-0008; update README/ARCHITECTURE wording for the rebuilt packages; close PR #214 as superseded | architect | claude | — | this ADR Accepted | `parallel-safe` |

That's at most 2 Claude agents at once, which is enough: F1 → F2 ∥ F3, then F4a → F4b.

## What would flip this decision

- **Fedora drops `Requires: setxkbmap` from calamares** (or gates it on X11, as sddm does): go back to Fedora's package and delete `build/rpms/calamares/`.
- **The runtime check in F4 shows KWin doesn't follow locale1 under the live session:** fall back to `configure.kwin: true` with a seeded live `kxkbrc`. That has a known risk: the reload signal goes out on root's session bus under kdesu. If that also fails, the next step is the C++ patch to `applyXkb()` and the plan's `decision` stop.
- **The owner rejects ZeeOS-built RPMs in the image entirely:** Option 2 (Anaconda WebUI) is the only Fedora-packaged route. It also needs a browser, a rewrite of the four zee-* modules, and still needs S for sddm. ADR-0003's resize-alongside argument then comes back.
