# Secure Boot chain

ZeeOS boots with Secure Boot **on** using only binaries that Microsoft and Fedora signed (ADR-0004). ZeeOS signs nothing itself: no custom shim, GRUB or kernel. That's what lets it boot on a stock Windows PC without enrolling any keys.

## The chain

```
UEFI firmware db: Microsoft UEFI CA (2011 and/or 2023)
  └─ shim         EFI/BOOT/BOOTX64.EFI | BOOTAA64.EFI   signed by Microsoft
       │  shim trusts its embedded vendor cert (.vendor_cert):
       │  "fedoraca" (Fedora Secure Boot CA 20200709), plus MOK (below)
       ├─ GRUB      EFI/BOOT/grubx64.efi | grubaa64.efi  signed by the Fedora CA
       └─ kernel    boot/<arch>/loader/linux             signed by the Fedora CA
            └─ kernel modules: signed by Fedora's build key (lockdown enforces it)
```

What a ZeeOS x86_64 ISO actually carries (checked on 2026-10-19):

| Binary | Signatures |
|---|---|
| shim | 1. Microsoft Windows UEFI Driver Publisher ← **Microsoft Corporation UEFI CA 2011** (the CA expired 2026-06-27; firmware ignores expiry)<br>2. Microsoft UEFI CA 2023 signer ← **Microsoft UEFI CA 2023** |
| GRUB | 1. fedora-signer-20250530 ← fedora-ca-20250530<br>2. kernel-signer ← **fedoraca**: this is the one shim accepts |
| kernel | kernel-signer ← **fedoraca** |

Firmware and shim accept a binary if **any** of its signatures chains to a trusted certificate. So shim boots both on firmware with only the 2011 CA in `db` (most PCs) and on firmware that has moved to the 2023 CA.

aarch64 follows the same scheme with `shimaa64`/`grubaa64` and the arm64 kernel. CI checks it the same way; see the `secureboot-chain (aarch64)` job.

## Automated check

`security/verify-secureboot-chain.sh <iso> [--tamper-test]` checks a built ISO the way firmware does:
1. shim has a signature that verifies against a Microsoft UEFI CA. Both CA certificates are fetched at run time and pinned by SHA-256; none are committed.
2. Shim's `.vendor_cert` is extracted and used as the only trust anchor for the next step.
3. GRUB and the kernel each have a signature that verifies against it.
4. With `--tamper-test`, a GRUB copy with one flipped byte must be **rejected**, which proves the check can fail.

`sbverify` checks only a binary's first signature, so `security/pe-split-signatures.py` writes one single-signature copy per signature. The Authenticode digest excludes the certificate table, so each copy still verifies.

CI runs it on every built ISO for both architectures (`build-iso.yml`, job `secureboot-chain`). It needs `sbsigntool`, `xorriso` (or `bsdtar`), `binutils`, `openssl`, `curl` and `python3`.

## Extra kernel modules (MOK)

The kernel enforces module signatures under Secure Boot. Out-of-tree modules (NVIDIA, VirtualBox host modules, DKMS/akmods) must be signed with a key the machine trusts. That key goes into the **Machine Owner Key** list, which shim manages:

1. Create a key once: `sudo kmodgenca -a`. On systems with akmods this happens automatically; otherwise use `openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 -outform DER -keyout mok.priv -out mok.der -subj "/CN=ZeeOS local module key/"`.
2. Queue it for enrolment: `sudo mokutil --import /etc/pki/akmods/certs/public_key.der` (or `mok.der`) and choose a one-time password.
3. Reboot. **MokManager** (blue screen) starts before GRUB: *Enroll MOK → Continue → Yes*, enter the password, *Reboot*.
4. Check: `mokutil --list-enrolled`. After that, akmods/DKMS sign modules with this key and they load with Secure Boot on.

Remove a key with `mokutil --delete <file.der>`, the same way. **Never** turn Secure Boot off to make a module load; enrol a MOK instead. The per-platform install guides (docs-writer, Phase 6) should link here.

## What would break the chain

- A rebuilt or self-signed shim, GRUB or kernel. ADR-0004 forbids it; the check would fail.
- A Fedora rebase that changes the vendor CA: shim and GRUB/kernel update together, and the check catches a mismatch.
- Microsoft revoking a shim via `dbx`/SBAT. Fedora ships a fixed shim; take it with the next lock refresh (ADR-0008), which `boot-test SECUREBOOT=on` checks for `boot-chain` PRs.
