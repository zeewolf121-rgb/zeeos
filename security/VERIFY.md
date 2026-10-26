# Verify a ZeeOS download

Verify the download before writing an ISO to a USB drive or opening a UTM bundle.
These checks authenticate release files; firmware Secure Boot is a separate check
described in [SECURE-BOOT.md](SECURE-BOOT.md).

## Get the files and establish trust

From the same tagged [ZeeOS release](https://github.com/zeewolf121-rgb/zeeos/releases),
download your image plus all five verification files:

- `SHA256SUMS` and `SHA256SUMS.minisig`
- `zeeos-ci.pub`, `zeeos-ci.pub.minisig` and `zeeos-root.pub`

Images are named `zeeos-<ver>-x86_64.iso`, `zeeos-<ver>-aarch64.iso`, or
`zeeos-<ver>-aarch64.utm.zip`. Replace `<ver>` with the release's version.
Keep the downloaded files together in a new folder. Verify the ZIP before extracting it.

Install minisign from its [official project](https://jedisct1.github.io/minisign/),
which links Windows, macOS and Linux downloads. On Windows, run the commands below
in PowerShell with `minisign.exe` on PATH. On macOS and Linux, use a terminal.
Change into the download folder first.

A key downloaded alongside an image is not itself a trust anchor. Before continuing,
compare the complete root public-key value (the second line of `zeeos-root.pub`)
with a copy you previously trusted or one confirmed directly by the ZeeOS owner
through a separate trusted channel. A matching short key ID or an unverified release
page alone is insufficient. On a first download, obtain that confirmation first.
No root key or fingerprint is invented by this guide.

## Authenticate the manifest

Run these commands in this order on every platform:

```text
minisign -Vm zeeos-ci.pub -p zeeos-root.pub
minisign -Vm SHA256SUMS -p zeeos-ci.pub
```

The first command checks the offline root's signature on the CI public key. The
second checks the CI key's signature on the checksum manifest. minisign finds each
corresponding `.minisig` file beside the file being checked. Both commands must
report successful verification and exit successfully. Stop if either fails, a
file is missing, or the root key is unfamiliar. Do not substitute an unverified key.

## Check the image bytes

After authenticating the manifest, find the entry for the exact image filename in
`SHA256SUMS`. Compare its full 64-character SHA-256 value with the result below.
Replace the example filename with your downloaded ISO or UTM ZIP. Letter case in
the hexadecimal digest does not matter; every digit must match.

Windows PowerShell:

```powershell
Get-Content .\SHA256SUMS
Get-FileHash -Algorithm SHA256 '.\zeeos-<ver>-x86_64.iso'
```

macOS:

```sh
cat SHA256SUMS
shasum -a 256 'zeeos-<ver>-x86_64.iso'
```

Linux:

```sh
cat SHA256SUMS
sha256sum 'zeeos-<ver>-x86_64.iso'
```

If you downloaded every image listed in the manifest, Linux can check them all
with `sha256sum -c SHA256SUMS`; macOS can use `shasum -a 256 -c SHA256SUMS`.
Every listed file must report `OK`, with a successful exit status. Missing files
are failures in this all-files mode. For a single download, use the exact-filename
comparison above. A checksum match without the signature checks is not authentication.

If a digest differs, stop and discard that image. Check the release notice before
downloading again. A valid old signature also does not prove that a release is
current: check the intended tag and any withdrawal or security notice.

## Maintainer key-rotation runbook

This implements [ADR-0007](../docs/adr/0007-release-signing.md). The owner performs
key operations. Agents must not generate production keys, read `MINISIGN_*`, or
write `security/keys/`. Root secret material stays offline; it never enters CI.

For a suspected or confirmed CI-key compromise:

1. Pause release publication and revoke the compromised CI credential. Preserve
   audit evidence and identify affected releases; do not re-sign untrusted artifacts.
2. The owner generates a replacement CI key in a trusted environment. On the
   offline root-key system, sign the replacement `zeeos-ci.pub` to produce
   `zeeos-ci.pub.minisig`. Check that signature using the already trusted root.
3. Through a reviewed PR, replace only the public CI key and its root signature
   under `security/keys/`. Publish the old and new complete public-key values, the
   effective date, affected tags and the compromise/rotation notice. minisign keys
   have no automatic expiry or online revocation check; users need this notice.
4. The owner replaces `MINISIGN_SECRET_KEY` and `MINISIGN_PASSWORD` in GitHub's
   protected `release` environment. Only the release workflow may consume them,
   with its required owner approval. Never paste secret values into logs or PRs.
5. Verify or rebuild affected artifacts from trusted inputs. Re-sign their manifests
   with the replacement CI key and publish the matching public key and root
   signature. If bytes change, publish a new version/tag rather than silently
   replacing an image. Clearly withdraw artifacts that cannot be trusted.
6. Download the published assets into a clean directory and perform the complete
   chain and checksum checks above. Link the successful release-verification CI
   run and the rotation notice before resuming normal publication.

Root-key compromise requires a separate owner-led trust migration: a signature
from the compromised root cannot establish trust in its replacement. Announce the
new complete root public key through independently trusted channels and require
users to establish trust again. Do not rotate the root through CI.
