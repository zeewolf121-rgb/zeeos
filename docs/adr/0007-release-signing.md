# ADR-0007: Release signing

- Status: **Accepted** (owner, 2026-10-16, Phase 0 decision D10)
- Date: 2026-10-16
- Deciders: owner; architect (Claude); reviewer (Codex)

## Context

Every release ships `SHA256SUMS` plus a signature (MISSION §2). Users must be able to verify downloads on Windows, macOS and Linux. Secure Boot signing is out of scope: v1 uses Fedora's signed shim, GRUB and kernel (ADR-0004), so ZeeOS signs release files only.

## Options

| Tool | Verify on Windows/macOS | Key handling | Notes |
|---|---|---|---|
| **minisign** | Single static binary, also `rsign2` and libsodium ports | Small Ed25519 keys, password-protected secret key file | No web of trust, no expiry. Simple to audit |
| GPG | Gpg4win / GPG Suite needed | Keyrings, subkeys, expiry | Familiar to Linux users, heavy for everyone else |
| Sigstore / cosign keyless | cosign binary | Ties trust to the CI identity + a public transparency log | Leaks repo/workflow identity; private repo today |

## Decision

**minisign**, with two keys:

| Key | Where the secret key lives | Signs |
|---|---|---|
| **Root key** | Offline only (owner's machine / hardware backup). Never in CI or the repo | The CI key's public key file (`security/keys/zeeos-ci.pub.minisig`), and optionally a countersignature on final releases |
| **CI signing key** | GitHub encrypted secrets: `MINISIGN_SECRET_KEY` (key file contents) and `MINISIGN_PASSWORD`, scoped to the `release` environment | `SHA256SUMS` → `SHA256SUMS.minisig` on every tagged release |

- Both public keys are committed under `security/keys/` and printed in the release notes and install guides.
- Users verify with `minisign -Vm SHA256SUMS -p zeeos-ci.pub`, then `sha256sum -c SHA256SUMS`. Anyone wanting the full chain also verifies `zeeos-ci.pub` against `zeeos-root.pub`.
- The release workflow is the only job that can read the CI key (GitHub `release` environment with required reviewer = owner).

## Consequences

- **Rotation:** if the CI key leaks, generate a new one, sign its public key with the root key, publish a notice, and re-sign the affected releases. The root key never rotates through CI.
- `security-hardener` (Codex) owns `security/keys/` and the verification docs. `ci-engineer` owns the signing step in `release.yml` (Phase 5).
- File names differ from the brief's `.sig`: minisign uses `.minisig`. The brief's intent (integrity + signature) is met.

## What would flip this decision

A distribution channel that requires GPG (e.g. a third-party mirror or package repo), or a move to a public repo where Sigstore's transparency log becomes an advantage.
