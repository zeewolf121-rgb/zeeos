# /installer

Owner: `installer-engineer` (see docs/agents.md). Other agents: open an issue instead of editing here.

## Modules

- `modules/zee-espbackup/` (#177, `installer-disk`): Calamares job that tars the existing ESP to `/var/lib/zeeos/esp-backup-<UTC>.tar` on the target, with a SHA-256 manifest, before any bootloader write. Reads the ESP only; dry run via globalstorage `zeeDryRun` or `ZEE_DRY_RUN=1`. Tests: `python3 -m unittest discover -s installer/modules/zee-espbackup/tests` (also in `make lint`).
