# /security

Owner: `security-hardener` (see docs/agents.md). Other agents: open an issue instead of editing here.

- `SECURE-BOOT.md`: the Secure Boot chain (Microsoft UEFI CA -> shim -> Fedora CA -> GRUB, kernel), what the ISO carries, and the MOK path for extra modules.
- `verify-secureboot-chain.sh` + `pe-split-signatures.py`: check that chain in a built ISO (CI job `secureboot-chain`).
