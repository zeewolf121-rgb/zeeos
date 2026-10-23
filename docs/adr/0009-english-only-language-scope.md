# ADR-0009: Language scope: English only (Arabic/RTL requirement dropped)

- Status: Proposed
- Date: 2026-10-23
- Deciders: owner; architect (Claude); reviewer (Codex)

## Context

`docs/MISSION.md` asked for "Arabic + English locales (RTL tested)" in the installer and for "Arabic/RTL" in Phase 3. That requirement became concrete work in several directories:

- **build:** `build/common/packages.xml` lists `glibc-langpack-ar`, `google-noto-sans-arabic-vf-fonts` and `google-noto-naskh-arabic-vf-fonts` explicitly (P3-1). Both `packages.lock` files pin them.
- **desktop:** `zeeos-layout-check` switches the session to `ar_EG.UTF-8` after the three layout modes and prints `ZEEOS_RTL_OK` / `ZEEOS_RTL_FAIL` (P3-6).
- **vm / ci:** `vm/boot-test.sh` and `.github/workflows/boot-test.yml` require `ZEEOS_RTL_OK`, take `screenshot-rtl.ppm` and treat `ZEEOS_RTL_FAIL` as a failure (P3-7). `tests/fixtures/serial-layout-ok.log` and `tests/selftest.sh` replay that marker.
- **installer:** P4-2 and P4-6 promise Arabic in the language list and "RTL-correct" views. `.claude/agents/installer-engineer.md` says "Test Arabic RTL in every view you add."
- **docs:** MISSION, ARCHITECTURE (ISO size risk), Phase 2/3/4 plans.

The owner has decided that Arabic is no longer a ZeeOS requirement (tracking issue #203). Without an ADR, the mission text and the current tests disagree with that decision.

## Options

1. **Keep Arabic/RTL as a requirement.** This is what ships today. The owner rejected it.
2. **English only for ZeeOS-specific work, upstream multilingual support untouched.** ZeeOS stops adding Arabic packages, checks and promises. Fedora, Qt, KDE and Calamares keep whatever locales and RTL support they ship by default.
3. **Strip all non-English support** (remove upstream langpacks, translations, bidi libraries). This is a lot of work for little gain, it fights upstream defaults, and it would break users who choose another language. Rejected.

## Decision

**Option 2.**

- ZeeOS's own requirement is **English** (`en_US.UTF-8`). The installer must offer and default to English. ZeeOS does not promise or test any other language.
- ZeeOS does not **explicitly** provision Arabic: no `glibc-langpack-ar` or Noto Arabic entries in `packages.xml`. If such a package still arrives as a dependency of something else, it stays. Lock files are refreshed by the pin scripts (ADR-0008), never edited by hand.
- **No Arabic/RTL acceptance gate.** The guest RTL step, the `ZEEOS_RTL_OK` / `ZEEOS_RTL_FAIL` markers, `screenshot-rtl.ppm` and the matching fixtures and baselines are removed. The light, dark, `windows`, `mac` and `hybrid` checks stay as they are.
- **Leave upstream alone.** Don't patch out Qt/KDE/Calamares translations, ICU/HarfBuzz/fribidi or generic Unicode support. Users can still add locales after install.
- **History stays.** Accepted ADRs (0003's RTL row, 0006's OFL font examples) and older phase records are not rewritten. This ADR supersedes only the Arabic/RTL *requirement*, not the facts recorded in them.

### Landing order

The guest prints the marker and the harness requires it, so the order matters. Otherwise the boot cells go red in between:

1. **vm (#206) and ci (#209):** stop requiring `ZEEOS_RTL_OK` and `screenshot-rtl.ppm`. `*_RTL_FAIL` keeps failing the cell until step 2 lands, so a guest that still runs the step can't fail quietly. Fixtures and selftests change in the same PR.
2. **desktop (#205):** remove the RTL step and both markers from `zeeos-layout-check`.
3. **build (#207):** remove the three Arabic package entries and refresh both locks with the pin workflow. This goes last because the step-2 guest no longer needs them.
4. **installer (#208)** and **docs (#204)** don't depend on the others and can land at any point.

At most 3 Claude agents run at once, starts staggered 5 minutes apart (MISSION §11). #206 and #209 touch different directories and are parallel-safe. #205 waits for both. #207 waits for #205.

## Consequences

- The ISO gets slightly smaller (the Noto Arabic VF fonts and the langpack). ARCHITECTURE risk 4 no longer needs to account for Arabic.
- Each boot cell does one stage and takes one screenshot fewer. The image-diff gate (P3-8) will not get an `rtl` baseline. None is committed under `build/arch/<arch>/baselines/` yet, so P3-11 just commits one baseline fewer per arch.
- **Signed boot chain:** no effect on either architecture. shim, GRUB, the kernel and the Secure Boot marker don't change on x86_64 or aarch64. The GRUB theme font subset (`branding/grub`) already makes no claim about Arabic, so it stays as it is.
- Disk-safety rules and the installer-disk modules are unchanged. Only the language list and the review checklist change.
- `.claude/agents/installer-engineer.md` needs its RTL line removed. Agents can't edit `.claude/`, so that change needs a separate human-owned issue.

## What would flip this decision

The owner asks again for a specific non-English locale. That locale would come back through a new ADR that names the language, its packages and its acceptance check. It would not reopen this one.
