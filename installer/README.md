# /installer

Owner: `installer-engineer` (see docs/agents.md). Other agents: open an issue instead of editing here.

## Language scope (ADR-0009)

English only. The Calamares `locale` module defaults to `en_US.UTF-8`, and the installer's own strings and branding are English. ZeeOS doesn't provision any Arabic locale or font in the installer, and no view needs an Arabic/RTL acceptance check (P4-2, P4-6 `zee-summary`, P4-9 unattended preset). Upstream Calamares translations and the language list stay as shipped; we just don't promise or test them. This scope doesn't relax anything else: the mandatory backup confirmation, the disk safeguards, LUKS2, Windows Boot Manager safety, `installer-disk` and dry-run coverage all stay.

## Calamares configuration (P4-2, #176, `installer-disk`)

`calamares/` is what the image installs: `settings.conf` → `/etc/calamares/settings.conf`, `calamares/modules/*.conf` → `/etc/calamares/modules/`, `calamares/branding/zeeos/` → `/etc/calamares/branding/zeeos/`, and each `modules/zee-*/` → `/usr/lib/calamares/modules/zee-*/`. Copying them into the image is image-builder's job (`build/build-iso.sh`), tracked in a follow-up issue.

- Sequence: welcome, locale, keyboard, partition, users, summary; then partition, mount, unpackfs, …, live cleanup, removeuser, remove calamares, dracut, `zee-espbackup`, `zee-bootloader`, umount. Slots for `zee-preflight` (after partition), `zee-summary` (in place of summary) and `zee-bootmenu` (after `zee-bootloader`) are marked in `settings.conf`.
- `partition`: erase / alongside / manual, LUKS2 option for the btrfs root, Fedora's layout (ESP, ext4 `/boot`, btrfs `/` with `root`/`home` subvolumes). An existing ESP is reused, never formatted.
- `unpackfs` rsyncs the running live root (`/boot/efi/*` excluded). The live-only parts are removed on the target: SDDM and serial auto-login, the guest test units and scripts, `liveuser` and its home (removeuser), passwordless root (locked), and the `calamares` packages (ADR-0011).
- `zee-bootloader` replaces the stock `bootloader` module, whose `grub` mode runs `grub2-install` and builds an unsigned image (ADR-0004). It copies Fedora's signed shim + GRUB into `\EFI\fedora\` only (refusing a non-empty one) and writes the GRUB stub, then runs `grub2-mkconfig`. It never writes `\EFI\Microsoft\` or `\EFI\BOOT\`. The NVRAM entry is `zee-bootmenu` (P4-7).
- `keyboard`: `useLocale1: true`, `configure.kwin: false`, no setxkbmap (ADR-0011).
- **Dry run:** `python3 installer/tools/zee-plan.py [--mode erase|alongside|manual] [--luks]` checks the disk-safety rules on the shipped config and prints every planned disk operation. It opens no disk. Each `zee-*` job also honours `zeeDryRun` / `ZEE_DRY_RUN=1`.
- Tests: `python3 -m unittest discover -s installer/tools/tests` (needs PyYAML) and `python3 -m unittest discover -s installer/modules/zee-bootloader/tests`.

## Unattended CI install (P4-9, #181, `installer-disk`)

`autoinstall/` runs Calamares without a user, for `install-test` only. Nothing runs without the preset disk, so `boot-test` doesn't change.

- `90-zeeos-autoinstall.rules` (→ `/usr/lib/udev/rules.d/`) pulls in `zeeos-autoinstall.service` (→ `/usr/lib/systemd/system/`, enabled by no target) only for a virtio disk with serial `ZEEOS-AUTOINSTALL`. The unit also requires `rd.live.image`.
- `zeeos-autoinstall` (→ `/usr/libexec/`) reads `key=value` lines from byte 0 of `/dev/disk/by-id/virtio-ZEEOS-AUTOINSTALL` up to the first NUL. The keys are `case`, `user`, `password` and `luks_passphrase`, and any other key is an error, so there is no switch to skip a module. It prints `ZEEOS_INSTALL_START`/`DONE`/`FAIL <module>: <reason>` to the serial console and powers off. It refuses to start (`FAIL autoinstall: …`) while `zee-preflight` isn't installed. The preset goes to the root-only `/run/zeeos-autoinstall/preset.json`, never to globalstorage or a command line. Dry run: `--dry-run` or `ZEE_DRY_RUN=1`.
- `settings.conf` (→ `/usr/share/zeeos/autoinstall/`) is the exec-only sequence: `zee-preflight` first, then `zee-autopart`, then the same jobs as the interactive install with `zee-autopreset` instead of `users`, and `zee-autodone` last. Calamares runs with `QT_QPA_PLATFORM=offscreen` and a config dir built in `/run/zeeos-autoinstall/calamares/`.
- Failure contract: a job that fails writes `<module>: <reason>` to `/run/zeeos-autoinstall/fail`, which becomes the `ZEEOS_INSTALL_FAIL` line. `zee-preflight` must do the same, as `preflight: …`. Otherwise the runner names the last job in Calamares' `session.log`.
- `modules/zee-autopart/`: unattended `erase` and `luks` only, with `partition.conf`'s layout (ESP 600 MiB, ext4 `/boot` 2 GiB, btrfs root, LUKS2 around root for `luks`). It writes only a disk with no partition table and no filesystem signature, and only when exactly one candidate disk exists. It refuses `alongside` for now.
- `modules/zee-autopreset/`: creates the preset user (wheel) and installs the test-only first-boot unit `firstboot/zeeos-install-markers`. On the installed system that unit prints `ZEEOS_BOOTMENU …`, `ZEEOS_ROOTFS …` and then `ZEEOS_DESKTOP_READY` once SDDM's Wayland greeter is up (installed systems have no auto-login).
- The live cleanup removes the autoinstall files from the target.
- Tests: `python3 -m unittest discover -s installer/tools/tests` (runner and markers) and `-s installer/modules/zee-autopart/tests`.

## Modules

- `modules/zee-bootloader/` (#176, `installer-disk`): Fedora's signed shim + GRUB into `\EFI\fedora\`, GRUB stub, `grub2-mkconfig`. Dry run via `zeeDryRun` or `ZEE_DRY_RUN=1`.

- `modules/zee-espbackup/` (#177, `installer-disk`): Calamares job that tars the existing ESP to `/var/lib/zeeos/esp-backup-<UTC>.tar` on the target, with a SHA-256 manifest, before any bootloader write. Reads the ESP only; dry run via globalstorage `zeeDryRun` or `ZEE_DRY_RUN=1`. Tests: `python3 -m unittest discover -s installer/modules/zee-espbackup/tests`.

- `modules/zee-summary/` (#178, P4-6): C++ `qtplugin` view module + `zee-summary.qml`, to replace the stock summary page (stock `summary`/`summaryq` can't hold Install back). It lists every queued `partition` job per disk (grouped by the `/dev/...` node each job names, `DiskPlan.cpp`) and keeps Install disabled until "I have a backup" is checked. The box resets on every visit, so a changed layout has to be confirmed again, and an empty plan keeps Install disabled. It queues no jobs and writes nothing. The page mirrors for RTL languages and keeps device paths as LTR runs. The unattended preset (P4-9) checks the box explicitly with `presets: { backupConfirmed: { value: true, editable: false } }` in `zee-summary.conf`; the shipped config never does. Build against `calamares-devel`: `cmake -S installer/modules/zee-summary -B <dir> && cmake --build <dir> && ctest --test-dir <dir>` (without `calamares-devel` only the `DiskPlan` test builds). `settings.conf` still shows the stock `summary`: the image copies `modules/zee-*/` verbatim, so it has no `.so` for this plugin yet. Switch to `zee-summary` once image-builder compiles it (`zee-plan.py` accepts exactly one of the two as the last page before the install).
