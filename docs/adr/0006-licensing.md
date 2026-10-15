# ADR-0006: Licensing

- Status: **Accepted with change** (owner, 2026-10-16, Phase 0 decision D6: name and logo excluded)
- Date: 2026-10-16

## Decision

| Content | License | Why |
|---|---|---|
| Code (scripts, Calamares modules, KWin scripts, QML, CI) | **GPL-3.0-or-later** | Compatible with Calamares (GPL-3.0) and KDE (GPL-2.0-or-later / LGPL) code we extend |
| Config files | GPL-3.0-or-later | Simple, consistent |
| Docs | CC-BY-SA-4.0 | Same as artwork |
| Artwork (themes, icons, wallpapers, sounds) | **CC-BY-SA-4.0** for original work. Third-party assets keep their own license | Lets others remix, keeps attribution |
| Fonts | SIL OFL-1.1 only (e.g. Inter, Noto Sans Arabic, IBM Plex Sans Arabic) | Allowed to redistribute and embed |
| "ZeeOS" name and logo | **All rights reserved**, not under any of the licenses above. Policy in [`TRADEMARKS.md`](../../TRADEMARKS.md) | Forks shouldn't ship with our brand |

## Rules

- The repo follows the **REUSE** spec. Every file has an SPDX header or a `REUSE.toml` entry. License texts live in `/LICENSES/`.
- Logo files are annotated `LicenseRef-ZeeOS-Trademarks` in `REUSE.toml`. The first PR that adds a logo file also adds `LICENSES/LicenseRef-ZeeOS-Trademarks.txt` (`reuse lint` rejects unused licenses, so it can't land earlier).
- `lint.yml` runs `reuse lint`. Any asset in `/branding` without a known license fails CI.
- Banned outright: Segoe UI, SF Pro / SF Symbols, Microsoft/Apple icons, wallpapers or sounds, and anything "free for personal use".
