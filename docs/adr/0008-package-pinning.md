# ADR-0008: Package pinning for reproducible builds

- Status: **Proposed** (needs owner decision and Codex cross-review)
- Date: 2026-10-16
- Deciders: owner; architect (Claude); reviewer (Codex)

## Context

Issue #45 (split from #7) asks that `make iso` from a clean checkout uses only pinned inputs. Two builds of the same commit, a day apart, must give the same package list. The pins also need a scripted refresh. This is what main does today:

- **Build container.** `build/container/base-image.lock` pins the Fedora 44 base image by digest (`make pin-container`). After that, the `Containerfile` runs `dnf -y install kiwi-cli kiwi-systemdeps-* xorriso squashfs-tools ...` against the live Fedora repos with no version pins. The same base digest can therefore produce different tool versions.
- **ISO packages.** `build/arch/<arch>/config.xml` points kiwi at the `fedora-44` and `updates-released-f44` metalinks. `build-iso.sh` swaps those for `$ZEEOS_SNAPSHOT_URL/releases/44/Everything/$arch/os` and `$ZEEOS_SNAPSHOT_URL/updates/44/Everything/$arch` only when that variable is set. Otherwise it prints a warning and uses the live mirrors.
- **What is pinned.** kiwi `<package>` entries name about 30 packages in `build/common/packages.xml` and the arch `config.xml`. dnf resolves every other package in the image to whatever the repo serves that day.
- **Reproducibility check.** `build/check-reproducible.sh` builds twice in a row and diffs `packages.list`. Back-to-back builds almost never catch repo drift.
- **CI runners.** `build-iso.yml` builds x86_64 on `ubuntu-24.04` and aarch64 on `ubuntu-24.04-arm`. ARCHITECTURE.md §4 still says aarch64 CI uses a self-hosted macOS runner. That needs a separate docs fix.

Facts about Fedora that this decision relies on. Each was checked on 2026-10-16:

1. **`releases/44` is frozen at GA.** It never changes, so it is already reproducible.
2. **`updates/44` keeps only the newest build of each package.** The mirror listing for `updates/44/Everything/x86_64/Packages/k/` contained a single `kernel-core` (7.2.10-200.fc44). Superseded NEVRAs disappear from mirrors. A NEVRA pin that relies only on mirrors breaks the build the next time Fedora pushes an update.
3. **Koji still serves superseded builds.** `kojipkgs.fedoraproject.org/packages/kernel/7.2.8/200.fc44/data/signed/6d9f90a6/` exists. Fedora documents no retention guarantee, and a build that never shipped (`bash-5.3.0-1.fc43`) had no signed copy at all. Koji is a useful fallback but not a source we can depend on.
4. **Fedora has no dated snapshot service.** Koji build-tag repos and updates composes are regenerated and garbage-collected on Fedora's schedule.

Constraints:
- The repo is public and runs on the GitHub free tier.
- Secrets live only in GitHub encrypted secrets (CLAUDE.md rule 6).
- Arch differences stay in `build/arch/<arch>/` (rule 4).
- The ISO must keep the Fedora-signed boot chain on both architectures (ADR-0004): `shim-x64` / `grub2-efi-x64` and `shim-aa64` / `grub2-efi-aa64`, plus `kernel`.

## Options

| | (a) NEVRA lockfile only | (b) Full dated mirror (reposync) | (c) Koji tags / frozen composes | (a+b′) Lockfile + closure repo (hybrid) |
|---|---|---|---|---|
| What is pinned | Every package NEVRA, but only if the lock covers the **full closure** (everything in `packages.list`). The ~30 names in `packages.xml` alone pin nothing transitive | The whole repo state at a date | A Koji tag or compose ID | Full closure NEVRA + sha256 per arch, plus one immutable repo holding exactly those RPMs |
| Reproducibility guarantee | **Breaks** once Fedora supersedes a pinned update (fact 2): the build fails rather than drifting | Strong while the snapshot is kept | **None we control**: composes and tag repos are GC'd (fact 4), tags move | Strong: the build can only see locked RPMs, and a lock/`packages.list` mismatch fails the build |
| Both arches | Lock per arch, resolved natively on each runner | 2× mirror per snapshot | Per-arch composes exist | One lock + one closure repo per arch, under `build/arch/<arch>/` |
| Hosting / cost | None | Tens of GB per arch per snapshot for Everything + updates (estimated, not measured). Doesn't fit the free tier; object storage needs a paid account and an upload credential | None (Fedora hosts) | Only the closure: estimated hundreds of MB per arch now, a few GB with Plasma. Hosted as a public GHCR OCI artifact, pushed with the workflow `GITHUB_TOKEN`, so no stored secret |
| Old NEVRAs downloadable | Not from mirrors. From Koji only best-effort | Yes, we keep them | No | Yes: we keep a copy at lock time, fetched from mirrors, with Koji as fallback |
| Signed boot chain | Unchanged (Fedora RPMs, gpgcheck) | Unchanged if gpgcheck stays on | Koji build-tag repos also serve unsigned RPMs; we'd have to turn gpgcheck off, which is **not acceptable** | Unchanged: RPMs are byte-identical Fedora-signed files, and kiwi keeps gpgcheck on against `fedora-gpg-keys` |
| Security updates | Refresh PR, then the build breaks until merged | New snapshot + PR | n/a | Refresh job publishes a new closure and opens a PR |
| Moving parts | Low | High (mirror job, storage, pruning) | Low, but fragile | Medium: resolve, fetch, publish and verify scripts |

## Decision

**Hybrid (a+b′): a committed full-closure lockfile per arch, served from a ZeeOS-published, immutable "closure repo" that holds exactly the locked, Fedora-signed RPMs. That repo is the default package source for `make iso`. The build container is published to GHCR and pinned by digest.**

### ISO packages

1. **Lockfile.** One per arch: `build/arch/<arch>/packages.lock`. Each line holds one installed package as `name epoch:version-release.arch sha256`. A header records:
   - the closure-repo OCI reference and digest,
   - the Fedora release (44),
   - the time the lock was resolved.

   The lock covers the full closure, meaning everything that ends up in `packages.list`, not just the names in `packages.xml`.
2. **Resolve.** A script under `build/` resolves the kiwi package list against the live `fedora` + `updates` repos inside the pinned build container. It runs natively on each arch's runner. `--forcearch` is a fallback; nothing installs, so scriptlets don't run.
3. **Fetch.** The script downloads each locked RPM from Fedora mirrors, falling back to `kojipkgs` signed copies (fact 3). It checks the sha256 and the Fedora GPG signature, runs `createrepo_c`, and packs the result as an OCI artifact. That artifact is published to `ghcr.io/<owner>/zeeos-closure-<arch>` and is addressed by digest.
4. **Build.** `make iso` pulls the closure repo by the digest in the lock (anonymous pull, no login) and points kiwi at it as the **only** repo. This replaces the two metalink/`ZEEOS_SNAPSHOT_URL` paths in `build-iso.sh`. kiwi keeps gpgcheck on. After the build, `packages.list` must match the lock exactly, otherwise the build fails. Mutable metalinks are only allowed behind an explicit developer opt-out (e.g. `ZEEOS_UNPINNED=1`), which CI and release builds never set and which marks the output unpinned.
5. **Installed system.** Repos inside the image stay the stock Fedora ones from `fedora-repos`. The closure repo exists at build time only, so installed systems update from Fedora as usual.

### Build-container tools

- Publish the built container image to `ghcr.io/<owner>/zeeos-build`, one image per arch, each built natively on that arch's runner. Pin it by digest in a lock next to `base-image.lock`.
- The `Containerfile` remains the recipe. When the image is published, `rpm -qa` is captured to `build/container/tools.lock` so tool versions are reviewable in the refresh PR.
- `make iso` pulls the pinned image. Building the image locally from the `Containerfile` is still possible, but it warns that it is unpinned, as `run.sh` already does for an empty base digest.
- Why: kiwi has to exist before any package repo is in use, and digest pinning is already the pattern for the base image. A second closure repo just for tools would add moving parts without adding any guarantee.

### Refresh and security-update flow

- A scheduled **daily** job runs the resolver against Fedora metadata on both arches, which is cheap. If either lock or the tools image changes, the job publishes the new artifacts and opens or updates a **single rolling PR**.
- The PR body lists the NEVRA diff and any Bodhi security advisories.
- A PR that bumps `shim-*`, `grub2-efi-*` or `kernel` on either arch gets a boot-chain label. It must pass `boot-test SECUREBOOT=on` on **both** arches before merge. Stale shim or GRUB pins risk SBAT/dbx revocation on updated firmware, so these PRs take priority.
- Owner and cross-review rules stay as they are (CONVENTIONS). No auto-merge.
- A PR opened with the default `GITHUB_TOKEN` does not trigger `pull_request` workflows. The job therefore needs a GitHub App or fine-grained token, stored in GitHub encrypted secrets, or the owner re-runs checks by hand. ci-engineer documents which one.
- Fedora rebases (ADR-0001) are just a refresh against N+1 repos in the rebase PR.

## Consequences

- Same commit, same lock, same package set, on any day, as long as the referenced closure artifacts exist. The day-apart acceptance check then becomes a scheduled job comparing a fresh build against the lock.
- **Retention:** closure and tool images referenced by a release tag or by main's current lock are never deleted. Unreferenced ones (rejected refresh PRs) may be pruned after 30 days.
- **GHCR as a dependency:** free hosting and bandwidth for public packages is GitHub's published terms as of today. This ADR does not verify it. If it changes, see the flip conditions.
- **Redistribution:** publishing Fedora binary RPMs is redistribution, just as the ISO already is. The closure artifact should carry the matching SRPMs, or the release process must provide the source offer. The owner should confirm which before the first release (ties to ADR-0006).
- **Security lag:** the ISO gets Fedora updates only through merged refresh PRs, so there is up to about a day of detection lag plus review time. Installed systems are unaffected (point 5).
- **CI time:** each build pulls one artifact per arch instead of resolving against mirrors. This is likely faster and removes mirror flakiness.
- Docs follow-up on acceptance: ARCHITECTURE.md §5 ("pinned to a dated snapshot") changes to "pinned to a per-arch closure lock". §4's aarch64 runner row gets corrected.

### Follow-up work by owning agent

| Agent | Work | Depends on |
|---|---|---|
| image-builder (`build/`, `Makefile`) | Lock format; `build/` resolve, fetch and publish scripts; `make pin-packages`; closure pull and only-repo wiring in `build-iso.sh` / `run.sh`; `packages.list`-vs-lock check; `ZEEOS_UNPINNED` opt-out; tool image lock and pull in `run.sh`; `tools.lock` capture; first locks for both arches | this ADR Accepted |
| ci-engineer (`.github/`) | Daily refresh workflow (both native runners, `packages: write`, opens the rolling PR, boot-chain label); publish job for the closure and build-container images; scheduled day-apart reproducibility job; PR-trigger token decision. **Workflow files can't be edited by unattended agents, so this needs an interactive session or the owner** | image-builder scripts |
| architect (`docs/`) | ARCHITECTURE.md §4/§5 updates; mark this ADR Accepted only after the owner decides | owner decision |

## What would flip this decision

- **GHCR is unusable** (limits, anonymous-pull, cost): keep the hybrid but move the closure to GitHub Release tarballs, which have a per-file limit (to check), or to object storage with an upload credential in secrets.
- **Fedora ships a dated snapshot service** (or a long-retention, signed updates archive): switch to (b) using Fedora's snapshots as `ZEEOS_SNAPSHOT_URL` and drop our closure hosting. The lockfile stays as the drift check.
- **The closure grows past the free tier**, or the owner funds hosting: use (b) with a real dated mirror.
- **The owner accepts "pinned but not durable"** (builds may fail until a refresh after any Fedora update): use plain (a), with mirrors and Koji as sources and no hosting.
