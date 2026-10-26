# /security

Owner: `security-hardener` (see docs/agents.md). Other agents: open an issue instead of editing here.

- `SECURE-BOOT.md`: the Secure Boot chain (Microsoft UEFI CA -> shim -> Fedora CA -> GRUB, kernel), what the ISO carries, and the MOK path for extra modules.
- `verify-secureboot-chain.sh` + `pe-split-signatures.py`: check that chain in a built ISO (CI job `secureboot-chain`).
- [VERIFY.md](VERIFY.md): authenticate release downloads on Windows, macOS and Linux;
  maintainer key-rotation and compromise response.
- [cve-allowlist.yaml](cve-allowlist.yaml): empty advisory exceptions list and its
  schema, including exact package matching and UTC expiry.
