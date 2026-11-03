#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Print the release notes body (Markdown): key fingerprints, verify commands for Windows, macOS
# and Linux, and the matching CHANGELOG.md section. Reads public key files only.
set -euo pipefail

usage() { echo "Usage: release-notes.sh <tag> [-k <keysdir>] [-c <changelog>]" >&2; }
[[ ${1:-} == -h ]] && { usage; exit 0; }
[[ $# -ge 1 ]] || { usage; exit 2; }
tag=$1; shift
here=$(dirname "$0")
keys=${KEYS_DIR:-"$here/../security/keys"} log=$here/../CHANGELOG.md
while getopts 'k:c:' o; do
  case $o in k) keys=$OPTARG ;; c) log=$OPTARG ;; *) usage; exit 2 ;; esac
done
ver=${tag#v}
for k in zeeos-ci.pub zeeos-root.pub; do
  [[ -f $keys/$k ]] || { echo "ERROR: missing $keys/$k" >&2; exit 1; }
done

# The minisign key ID is in the public key's comment line; the SHA-256 covers the key line.
keyid() { sed -n 's/^untrusted comment: minisign public key //p' "$1" | head -n1; }
keyline() { sed -n '2p' "$1"; }
keysum() { keyline "$1" | tr -d '\n' | sha256sum | cut -d' ' -f1; }

section() {
  [[ -f $log ]] || return 0
  # The heading's first token, without [ ] and a leading v, must equal the version exactly:
  # a substring match let "## v0.5.0-rc.10" stand in for v0.5.0-rc.1.
  awk -v v="$ver" '
    /^## / {
      if (on) exit
      t = $2; gsub(/^\[|\]$/, "", t); sub(/^v/, "", t)
      if (t == v) { on = 1; next }
    }
    on { print }' "$log"
}

cat <<EOF
## Verify your download

Every release is signed with [minisign](https://jedisct1.github.io/minisign/) (ADR-0007).
**First, establish trust in the root key.** The \`zeeos-root.pub\` attached to this release is not
a trust anchor: anyone who can replace release assets can replace it too, and the commands below
would still succeed. Before running them, compare the complete root public-key value in the table
below with a copy you already trust (for example from an earlier release or a checkout of the
repository), or get the owner to confirm it over a separate trusted channel. Do not rely on this
page alone. See \`security/VERIFY.md\`.

Download the ISO or UTM ZIP together with \`SHA256SUMS\`, \`SHA256SUMS.minisig\`,
\`zeeos-ci.pub\`, \`zeeos-ci.pub.minisig\` and \`zeeos-root.pub\` into one folder, then run:

**Linux**
\`\`\`sh
minisign -Vm zeeos-ci.pub -p zeeos-root.pub
minisign -Vm SHA256SUMS -p zeeos-ci.pub
sha256sum -c --ignore-missing SHA256SUMS
\`\`\`

**macOS**
\`\`\`sh
minisign -Vm zeeos-ci.pub -p zeeos-root.pub
minisign -Vm SHA256SUMS -p zeeos-ci.pub
shasum -a 256 -c --ignore-missing SHA256SUMS
\`\`\`

**Windows (PowerShell, minisign.exe on PATH)**
\`\`\`powershell
minisign.exe -Vm zeeos-ci.pub -p zeeos-root.pub
minisign.exe -Vm SHA256SUMS -p zeeos-ci.pub
Get-FileHash .\\zeeos-$ver-x86_64.iso -Algorithm SHA256   # compare with the line in SHA256SUMS
\`\`\`

Each minisign command must print "Signature and comment signature verified".
Details and key rotation: \`security/VERIFY.md\`.

## Signing keys

| Key | minisign key ID | SHA-256 of the key line | Public key |
|---|---|---|---|
| Root (offline) | \`$(keyid "$keys/zeeos-root.pub")\` | \`$(keysum "$keys/zeeos-root.pub")\` | \`$(keyline "$keys/zeeos-root.pub")\` |
| CI (signs SHA256SUMS) | \`$(keyid "$keys/zeeos-ci.pub")\` | \`$(keysum "$keys/zeeos-ci.pub")\` | \`$(keyline "$keys/zeeos-ci.pub")\` |

## Changes in $tag

EOF
body=$(section)
if [[ -n $body ]]; then printf '%s\n' "$body"; else echo "No CHANGELOG.md entry for $ver."; fi
