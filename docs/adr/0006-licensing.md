# ADR-0006: Licensing

- Status: **Proposed** (needs owner approval, labeled `decision`)
- Date: 2026-10-16

## Decision (proposed)

| Content | License | Why |
|---|---|---|
| Code (scripts, Calamares modules, KWin scripts, QML, CI) | **GPL-3.0-or-later** | Compatible with Calamares (GPL-3.0) and KDE (GPL-2.0-or-later / LGPL) code we extend |
| Config files, docs | GPL-3.0-or-later (docs: CC-BY-SA-4.0) | Simple, consistent |
| Branding (art, icons, wallpapers, sounds) | **CC-BY-SA-4.0** for original work. Third-party assets keep their own license | Lets others remix, keeps attribution |
| Fonts | SIL OFL-1.1 only (e.g. Inter, Noto Sans Arabic, IBM Plex Sans Arabic) | Allowed to redistribute and embed |
| "ZeeOS" name and logo | Trademark policy in `docs/TRADEMARK.md` | Forks shouldn't ship with our brand |

## Rules

- The repo follows the **REUSE** spec. Every file has an SPDX header or a `REUSE.toml` entry. License texts live in `/LICENSES/`.
- `security.yml` runs `reuse lint`. Any asset in `/branding` without a known license fails CI.
- Banned outright: Segoe UI, SF Pro / SF Symbols, Microsoft/Apple icons, wallpapers or sounds, and anything "free for personal use".
