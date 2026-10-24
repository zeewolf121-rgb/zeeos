# /installer

Owner: `installer-engineer` (see docs/agents.md). Other agents: open an issue instead of editing here.

## Language scope (ADR-0009)

English only. The Calamares `locale` module defaults to `en_US.UTF-8`, and the installer's own strings and branding are English. ZeeOS doesn't provision any Arabic locale or font in the installer, and no view needs an Arabic/RTL acceptance check (P4-2, P4-6 `zee-summary`, P4-9 unattended preset). Upstream Calamares translations and the language list stay as shipped; we just don't promise or test them. This scope doesn't relax anything else: the mandatory backup confirmation, the disk safeguards, LUKS2, Windows Boot Manager safety, `installer-disk` and dry-run coverage all stay.

## Modules

- `modules/zee-espbackup/` (#177, `installer-disk`): Calamares job that tars the existing ESP to `/var/lib/zeeos/esp-backup-<UTC>.tar` on the target, with a SHA-256 manifest, before any bootloader write. Reads the ESP only; dry run via globalstorage `zeeDryRun` or `ZEE_DRY_RUN=1`. Tests: `python3 -m unittest discover -s installer/modules/zee-espbackup/tests`.
