# ADR-0009: Scope of the Wayland-only rule for packaged X11 helpers

- Status: Proposed
- Date: 2026-10-23
- Deciders: owner, after Claude/Codex cross-review
- Related: hard rule 3 (CLAUDE.md), ADR-0001, ADR-0003, ADR-0005, ADR-0008, issue #210, draft PR #211 (issue #175)

## Context

Hard rule 3 says: "Wayland only. No X11 sessions or X11-only components." ADR-0003 (Accepted) picks Fedora's packaged Calamares. In #175, `dnf repoquery --requires calamares` on Fedora 44 (`calamares-3.3.14-5.fc44`, x86_64 and aarch64) lists `setxkbmap`, an X11 client tool. Calamares' keyboard module calls it to preview the chosen layout live. PR #211 stays a draft until this conflict is settled.

The rule never defines "X11-only component". Today's pinned closure on `main` (ADR-0008, `build/arch/{x86_64,aarch64}/packages.lock`, last refreshed in #163, before any Calamares change) already ships these X11 packages as dependencies of the Fedora KDE/Plasma set, on **both** architectures:

`setxkbmap`, `xkbcomp`, `xmodmap`, `xprop`, `xrdb`, `xorg-x11-xauth`, `xorg-x11-xinit`, `xorg-x11-server-Xwayland`, `libX11`.

So Calamares adds no new X11 package to the image. `setxkbmap 1.3.4-7.fc44` is already locked. The real question is what rule 3 means. A literal reading, "no package that only works with X11", already fails on `main` and would rule out Fedora KDE itself (ADR-0001), not just Calamares. Which locked package pulls in each helper is not recorded here. The image-builder should confirm that with `dnf repoquery --whatrequires` when the lock is next refreshed.

Signed boot chain: neither architecture is affected. These are userspace packages from Fedora's signed repos, installed after shim/GRUB/kernel (ADR-0004). Nothing here touches the bootloader, kernel, ESP or NVRAM.

## Options

| | A. Narrow, explicit exception (proposed) | B. Patch or rebuild Calamares without `setxkbmap` | C. Different installer | D. Literal rule, remove all X11 helpers |
|---|---|---|---|---|
| What changes | Rule 3 gets a precise definition (below) | Own RPM: drop the `Requires`, patch the keyboard module (e.g. to use `localectl`/KWin) | Anaconda or another installer | Strip X11 packages from the closure |
| Image contents | Same as today plus Calamares | Same as today: Plasma still pulls `setxkbmap` | Same as today | Must remove or break Plasma dependencies |
| Cost | Docs only | We maintain a forked RPM, its signing, and updates on 2 arches | Breaks ADR-0003; Anaconda has no resize-alongside flow | Rebuild or fork Fedora KDE packages; breaks ADR-0001's "no extra work" premise |
| Risk | Rule loses meaning if the exception spreads | Patch drift; we need our own repo signing key | Loses a core v1 requirement | High, and unbounded |
| Signed chain impact | None | New package-signing trust root (ADR-0007/0008 work) | None | None |

Rejected without a row: faking the dependency (`Provides: setxkbmap`, an empty shim package), `--nodeps`, or turning off RPM signature checks. #210 forbids these and they defeat ADR-0008.

## Decision (proposed)

**Option A.** Rule 3 means the **session and the user-facing workflows** are Wayland-only. It does not ban every binary that can talk to an X server. Concretely:

**Forbidden** (unchanged, still hard rule 3):
1. Any X11 session: no `plasma-workspace-x11`, `kwin-x11`, Xorg server (`xorg-x11-server-Xorg`), X11 `.desktop` session files, or SDDM X11 greeter config.
2. Any ZeeOS-owned code, config, script, autostart entry or test that **needs** an X server or X11 API to work: no `xdotool`/`xrandr`/`xprop`-based logic, no `DISPLAY`-only paths, no X11-only apps added to package lists by us.
3. Adding an X11-only package to `build/common` or `build/arch/*` package lists on purpose, whether or not a dependency already pulls it in.
4. Forcing an app to `QT_QPA_PLATFORM=xcb` or the GTK X11 backend in our launchers or configs.

**Allowed** (the new, narrow exception):
1. X11 client libraries and helpers pulled in **only as RPM dependencies** of packages we chose for Wayland reasons (Plasma, Calamares), unchanged from Fedora's signed repos and recorded in `packages.lock`.
2. Xwayland, as the Wayland compositor's compatibility layer for legacy apps the user runs. It runs inside the Wayland session and is not a session.
3. Calamares' keyboard preview calling `setxkbmap` and failing harmlessly under Wayland. That is fine **only if** the layout the user picks is still correctly written to the target (`localectl`/`/etc/vconsole.conf`, `/etc/X11/xorg.conf.d/00-keyboard.conf` as written by systemd-localed) and applied in the installed Wayland session.

Guard rails for the exception:
- The image-builder adds an image check (a follow-up, not this ADR) that fails if any forbidden item from list 1 is in either arch's lock or image.
- Every X11 helper added to the lock must show up in the PR diff of `packages.lock`, so a reviewer sees it (ADR-0008 already does this).
- Calamares runs under `kdesu` on the Wayland live session (Fedora's packaged entry). Real launch on both architectures must be proven by a CI boot or install test before #175 closes. If Calamares only works with `QT_QPA_PLATFORM=xcb` (Xwayland), this ADR does **not** allow that. It would need its own decision.

## Decisions needed from the owner and reviewers

1. Owner: is the session/workflow reading of rule 3 acceptable? If yes, a follow-up PR from whoever owns `docs/agent-context.md` and the CLAUDE.md sync (`scripts/sync-agent-docs.sh`) rewords rule 3 to link here. This ADR does not edit the hard rule.
2. Cross-review (Codex): check the forbidden/allowed lists, and confirm the lock evidence above (the helpers are already on `main`).
3. Owner: should Option B stay open as a later hardening step (a keyboard preview via KWin/`localectl` upstreamed to Calamares) rather than a fork?
4. image-builder (#175 / PR #211): confirm on both arches that the Calamares keyboard step writes the right layout to the target under Wayland. That is the condition for allowed item 3.

## Consequences

- PR #211 can go ahead once this ADR is Accepted. Until then it stays a draft, and the Calamares dependency is **not** yet permitted.
- Rule 3 becomes testable: a list of forbidden package names and code patterns instead of the undefined phrase "X11-only component".
- We accept a few dormant X11 binaries on the ISO (most already there). More attack surface is minimal: they need a reachable X server, and the only one is Xwayland inside the user's session.
- Follow-ups (each needs its own issue for the owning agent): rule 3 rewording; image check for forbidden X11 packages (image-builder or vm-integrator); keyboard-layout install test for both arches (vm-integrator).

## What would flip this decision

- Calamares on the Wayland live session cannot run without the xcb platform (Xwayland). Then reconsider B, or a Calamares build with a Wayland-native keyboard backend.
- Fedora moves `setxkbmap` to a weak dependency, or Calamares drops it upstream. Then the exception is no longer needed for the installer. Narrow it back to Plasma's dependencies.
- A dependency starts pulling in an X11 **session** package (forbidden list 1). That is never covered here, and needs a package exclusion or a new ADR.
- Security review finds a dormant helper exploitable without a running X server.
