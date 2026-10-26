#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Secret scan (P5-8, #274): gitleaks over the whole git history (every ref), pinned by version and
# SHA-256 (a mismatch fails closed). Findings are printed redacted.
# Usage: scripts/secret-scan.sh [repo-dir]      default: this repository
# Self-test: scripts/scan-selftest.sh (with cve-scan).
# GITLEAKS=<path> uses an already-verified binary; GITLEAKS_CACHE sets the download directory.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="${1:-$root}"
version=8.30.1
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) plat=linux_x64 sum=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
  Linux-aarch64 | Linux-arm64) plat=linux_arm64 sum=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
  Darwin-arm64) plat=darwin_arm64 sum=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
  Darwin-x86_64) plat=darwin_x64 sum=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709 ;;
  *) echo "secret-scan: no pinned gitleaks for $(uname -s)-$(uname -m)" >&2; exit 2 ;;
esac

bin="${GITLEAKS:-}"
if [[ -z "$bin" ]]; then
  cache="${GITLEAKS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zeeos/gitleaks-$version}"
  bin="$cache/gitleaks"
  if [[ ! -x "$bin" ]]; then
    mkdir -p "$cache"
    tgz="$cache/gitleaks_${version}_$plat.tar.gz"
    curl -fsSL --retry 3 -o "$tgz" \
      "https://github.com/gitleaks/gitleaks/releases/download/v$version/gitleaks_${version}_$plat.tar.gz"
    got="$( (sha256sum "$tgz" 2>/dev/null || shasum -a 256 "$tgz") | cut -d' ' -f1)"
    if [[ "$got" != "$sum" ]]; then
      rm -f "$tgz"; echo "secret-scan: gitleaks $version $plat sha256 $got, want $sum" >&2; exit 2
    fi
    tar -xzf "$tgz" -C "$cache" gitleaks
    rm -f "$tgz"
  fi
fi

# Default rules plus the lock-entry allowlist in scripts/gitleaks.toml (GITLEAKS_CONFIG overrides).
exec "$bin" git "$repo" --config "${GITLEAKS_CONFIG:-$root/scripts/gitleaks.toml}" \
  --log-opts=--all --redact --no-banner --exit-code 1
