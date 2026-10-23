# Phase 5 plan: hardening, Secure Boot proven, updates, signed releases, UTM bundle

**Exit criterion:** all of these on `main` (MISSION §13 item 5, §10.5, §10.9):

| # | Check | Arch | Evidence |
|---|---|---|---|
| 1 | `boot-test.yml` green on all four cells. Each serial log also has `ZEEOS_SECUREBOOT enabled=1` (SB-on cells) or `enabled=0` (SB-off cells) and `ZEEOS_HARDENING_OK …` (marker protocol below) | x86_64, aarch64 | CI run |
| 2 | `install-test.yml` case (a) still green, and the installed system prints `ZEEOS_HARDENING_OK … autoupdate=on` | x86_64, aarch64 | CI run |
| 3 | `utm-test` green: the disk inside `zeeos-<ver>-aarch64.utm` boots under QEMU + HVF on the self-hosted Mac to `ZEEOS_DESKTOP_READY` and `ZEEOS_HARDENING_OK … autoupdate=on` | aarch64 | CI run |
| 4 | A `release.yml` run on an owner-started rc tag (`v0.5.0-rc.N`, pre-release) publishes both ISOs, the UTM bundle, `SHA256SUMS` and `SHA256SUMS.minisig`, and its `verify-release` job passes against the committed public keys | both | CI run + release page |
| 5 | Secret scan and package CVE scan green on `main` | — | CI run |

The real UTM app on a Mac, and Rufus/Etcher USB boots, stay in the manual gate (MISSION §14). CI boots the bundle's disk with QEMU, the same backend UTM uses, not the UTM app.

**Boot chain:** unchanged on both architectures. ZeeOS still signs nothing that firmware or shim checks (ADR-0004, ADR-0007). minisign signs release files only. Hardening is userland config (firewall, sshd, dnf, SELinux mode check). The UTM disk is a kiwi-ng `oem` image from the same description (ADR-0002), with the same Fedora shim → GRUB → kernel files in its ESP. UTM's QEMU firmware may not have Microsoft keys enrolled. If so, the bundle boots with Secure Boot off, and P5-7 documents that. The chain is the Fedora one either way, and SB-on for aarch64 is still proven by boot-test check 1.

## Scope rules for this phase

- **Fedora defaults first.** Every hardening setting is one Fedora already ships or a drop-in file over it: `sshd_config.d/`, firewall zone files, `dnf5` automatic config, `/etc/selinux/config`. No custom daemons. Package names are checked with `dnf repoquery` in the build container, not guessed.
- **Decisions before code.** ADR-0009 (P5-1) picks the firewall front end (firewalld with its nftables backend, or a plain `nftables.service` ruleset), the sshd default (installed or not, enabled or not), and the auto-update policy (security only, when it reboots). P5-2 and P5-3 implement the accepted ADR.
- **Hardening files live in `security/overlay/`**, copied as-is onto the image root (the same pattern as `desktop/live/overlay/`, #68). P5-3 wires the copy. P5-2 fills it. Both work from this contract, so they can run in parallel.
- **Live session vs installed system.** The live session keeps SELinux enforcing and the firewall on, but doesn't run auto-updates (`autoupdate=live-off`). Calamares (Phase 4) and the UTM first boot get `autoupdate=on`.
- **No default passwords.** The UTM disk is not a live image. It has no `liveuser` and no auto-login. It creates the first user on first boot with what Fedora ships (`dnf repoquery` decides between `plasma-setup` and `initial-setup`). Only the CI test preset may seed a user, and only from a seed disk, as in Phase 4.
- **Keys and secrets are owner-only.** No agent writes `security/keys/`, generates a real key, or reads `MINISIGN_*`. Tests use a throwaway key pair made at test time and never committed.
- **Workflow edits are orchestrator tasks** (`needs-human`). Agents write the scripts the workflows call (`/scripts`, `/vm`, `/security`). Each script must run locally with a dry-run or fixture mode, so it is CI-testable before the workflow exists.

## Marker protocol (fixed here so P5-2, P5-4 and P5-7 can run in parallel)

Printed on the serial console by a guest check unit from P5-2. The unit runs on every live boot, and on installed systems only when a test preset installed it (Phase 4 rule):

```
ZEEOS_SECUREBOOT enabled=<0|1>       # from mokutil --sb-state or the SecureBoot EFI variable
ZEEOS_HARDENING_CHECK                # announce; without it the harness checks nothing new
ZEEOS_HARDENING_OK selinux=enforcing firewall=<firewalld|nftables> inbound=deny sshd=<off|keyonly> autoupdate=<on|live-off>
ZEEOS_HARDENING_FAIL <item>: <reason>
```

The harness (P4-8 `install-test.sh`, P5-4 `boot-test.sh`, P5-7 `utm-test.sh`) fails the cell if:
- `SECUREBOOT=on` and the guest reports `enabled=0`, or the other way round,
- the announce appears but `ZEEOS_HARDENING_OK` doesn't (with `THEME_TIMEOUT`), or `ZEEOS_HARDENING_FAIL` appears.

junit gets `secureboot` and `hardening` properties and one `boot.step` testcase for the hardening check.

## Release asset names (MISSION §2)

| Asset | Built by | Notes |
|---|---|---|
| `zeeos-<ver>-x86_64.iso` | build-iso | renamed from the kiwi output by P5-8 |
| `zeeos-<ver>-aarch64.iso` | build-iso (self-hosted Mac) | |
| `zeeos-<ver>-aarch64.utm.zip` | P5-7 on the Mac | A `.utm` bundle is a directory, and a release asset must be a file. Users unzip it to `zeeos-<ver>-aarch64.utm`. **Owner to confirm this name** (MISSION §2 says `.utm`) |
| `SHA256SUMS`, `SHA256SUMS.minisig` | release publish job | `.minisig`, not `.sig` (ADR-0007) |
| `zeeos-ci.pub`, `zeeos-ci.pub.minisig`, `zeeos-root.pub` | copied from `security/keys/` | so the release page alone is enough to verify |

**Size risk:** GitHub release assets must each be under 2 GiB, but `build-iso.yml` only checks for < 4 GB. P5-6 makes the publish step fail early on any asset ≥ 2 GiB. If an ISO is over, that's a `decision` issue (trim packages, or split hosting), not a silent workaround. The UTM disk goes into the bundle as compressed qcow2.

## Issues (concurrency cap: MISSION §11)

| ID | Title | Agent | Model | Arch | Budget | Deps |
|---|---|---|---|---|---|---|
| P5-1 | ADR-0009 hardening defaults: firewall front end and default zone (inbound deny; decide which Fedora defaults such as mDNS stay open), sshd default and key-only drop-in, `dnf5` automatic (security only, no auto-reboot), SELinux enforcing check, the live-off rule. Also fix the `security/secure-boot.md` → `security/SECURE-BOOT.md` path in `docs/ARCHITECTURE.md` §3 | architect | claude | both | small 15 | — `parallel-safe` · `decision` |
| P5-2 | `security/overlay/`: the drop-ins from ADR-0009, and the guest check unit + script that prints the marker protocol above (live: every boot; installed: test preset only). `tests`-style self-test of the check script against fake `/sys` and `/etc` trees | security-hardener | codex | both | medium 40 | P5-1 |
| P5-3 | Image wiring: copy `security/overlay/` onto the image root; packages per ADR-0009 (e.g. `firewalld` or `nftables`, `openssh-server`, the `dnf5` automatic plugin, `mokutil`) via `dnf repoquery`; refresh both locks; mask the auto-update timer in the live session only | image-builder | claude | both | small 15 | P5-1 (packages); `parallel-safe` with P5-2 (overlay contract) |
| P5-4 | `vm/boot-test.sh` and `vm/install-test.sh`: the hardening and Secure Boot marker checks, junit properties, fixture serial logs in `tests/` (pass, fail, SB mismatch, no announce) | vm-integrator | claude | both | small 15 | — `parallel-safe` (marker protocol above) |
| P5-5 | aarch64 `oem` disk image: a kiwi-ng profile in `build/arch/aarch64/` from the shared description (GPT, ESP with shim/GRUB, Fedora's default root filesystem), no live-only parts, first-user creation on first boot, `make utm-disk ARCH=aarch64`. Only ADR-0002's raw disk, no second build tool | image-builder | claude | aarch64 | large 80 | P5-3 (same packages and locks) |
| P5-6 | Release scripts in `/scripts`: `release-assets.sh` (rename to the names above, size check < 2 GiB, `SHA256SUMS`), `verify-release.sh <dir\|tag>` (`minisign -Vm` with `security/keys/zeeos-ci.pub`, `zeeos-ci.pub` against `zeeos-root.pub`, `sha256sum -c`; must fail on a tampered ISO and on a wrong key), `release-notes.sh` (key fingerprints, verify commands for Windows/macOS/Linux, the `CHANGELOG.md` section). Self-tests with a throwaway key | ci-engineer | claude | both | medium 40 | — `parallel-safe` |
| P5-7 | `vm/utm/`: `config.plist` template (QEMU backend, `virt` machine, UEFI, virtio-gpu, virtio-net, SPICE guest tools, 4 GB RAM, 4 vCPU), `make-bundle.sh` (raw → compressed qcow2 → `.utm` → `.utm.zip`, dry-run mode), `utm-test.sh` (unpack the bundle, boot its disk with QEMU + HVF using the plist's firmware and devices, wait for the markers, junit). Record whether UTM's firmware enforces Secure Boot | vm-integrator | claude | aarch64 | medium 40 | P5-5 (a real disk); P5-4 (marker checks) |
| P5-8 | CI scan scripts: `scripts/secret-scan.sh` (gitleaks, pinned by version and SHA-256, repo history), `scripts/cve-scan.sh` (both `packages.lock` files against Fedora `updateinfo` in the build container; fails on an unfixed critical/important advisory unless it's listed with a reason and expiry date in `security/cve-allowlist.yaml`) | ci-engineer | claude | both | medium 40 | — `parallel-safe` |
| P5-9 | `security/VERIFY.md`: how users verify a download on Windows, macOS and Linux (minisign + checksums), the full chain to the root key, and the ADR-0007 key-rotation runbook. `security/cve-allowlist.yaml` format + an empty file | security-hardener | codex | both | small 15 | — `parallel-safe` |

The Codex lane (P5-2, P5-9) runs one issue at a time. P5-9 goes first if ADR-0009 isn't accepted yet.

## Orchestrator and owner tasks (not opened by autopilot)

- **P5-K (owner):** generate the minisign root key offline and the CI key. Commit `security/keys/zeeos-root.pub`, `zeeos-ci.pub` and `zeeos-ci.pub.minisig`. Set `MINISIGN_SECRET_KEY` and `MINISIGN_PASSWORD` in the `release` environment (ADR-0007). Needed before P5-R. Not needed for P5-6, whose tests use throwaway keys.
- **P5-W1** `release.yml`: call `release-assets.sh`. Add a `utm` job on `[self-hosted, macOS, ARM64, zeeos-aarch64]` that builds the oem disk and runs `make-bundle.sh`. Publish the key files. Add a `verify-release` job after `publish` that downloads the release and runs `verify-release.sh`. Use `release-notes.sh` for the body. After P5-6 and P5-7. `needs-human`.
- **P5-W2** `boot-test.yml` / `build-iso.yml`: an aarch64 `utm-test` cell on the Mac (oem disk → bundle → `utm-test.sh`), on PRs that touch `build/`, `vm/utm/` or `security/overlay/`, and nightly. After P5-5 and P5-7. `needs-human`.
- **P5-W3** `security.yml` (or a `lint.yml` job): run `secret-scan.sh` and `cve-scan.sh` on every PR and nightly. After P5-8. `needs-human`.
- **P5-R (owner):** push `v0.5.0-rc.1` (pre-release; release.yml's guard accepts rc tags). This run is exit check 4. Autopilot still starts release candidates only after Phase 6 (AUTOPILOT §8).
- **Milestone:** `Phase 5: Hardening and release` exists; this plan's issues go into it.

## Lanes

```
Lane D (Codex): P5-9 ─► P5-2 ──────────────┐
Lane A:  P5-1 ─► P5-3 ─► P5-5 ─► P5-7 ─► P5-W2 ┤
Lane A:  P5-4 ──────────────────┘          │
Lane C:  P5-6 ─► P5-W1 (+ P5-K) ─► P5-R ───┤
Lane C:  P5-8 ─► P5-W3 ────────────────────┴─► integration checkpoint (exit test on main)
```

Day one: P5-1, P5-4 and P5-6 (three Claude agents, staggered 5 minutes apart) plus P5-9 (Codex). P5-8 starts when one of those slots frees up.

## Carried over

- **#9 and #15 are done.** They moved here from Phase 1 (phase-2.md). #9 (PR #124) ships `security/SECURE-BOOT.md` (the chain for both arches and the MOK path) and the `secureboot-chain` CI job. #15 (PR #186, then #192) put the aarch64 build and boot cells on the self-hosted Mac. Phase 5 builds on both and doesn't reopen them. "Secure Boot verified" here means check 1's in-guest `ZEEOS_SECUREBOOT` marker, on top of the signature check from #9.
- **Phase 4 dependency:** exit check 2 needs `install-test.yml` (P4-W) on `main`. If Phase 4 isn't closed when everything else here is green, check 2 carries into Phase 6 with a note in the phase report. The rest of the exit test isn't blocked by it.
- Phase 3 leftovers that don't block this phase: #131/#137, #136, #170.
