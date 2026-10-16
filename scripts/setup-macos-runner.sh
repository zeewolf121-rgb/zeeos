#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Idempotent setup of the self-hosted macOS ARM64 runner host (D9,
# docs/ci/macos-arm64-runner.md): brew tools and the rootful podman machine.
# Does NOT register the runner and never handles the registration token.
# Usage: scripts/setup-macos-runner.sh [--dry-run]
set -euo pipefail
dry=0
[[ "${1:-}" == "--dry-run" ]] && dry=1
machine="${ZEEOS_PODMAN_MACHINE:-zeeos}"

run() { printf '+ %s\n' "$*"; [[ $dry -eq 1 ]] || "$@"; }

if [[ $dry -eq 0 ]]; then
  [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "needs Apple Silicon macOS" >&2; exit 1; }
  command -v brew >/dev/null || { echo "install Homebrew first (see docs/ci/macos-arm64-runner.md)" >&2; exit 1; }
fi

for pkg in podman qemu jq gh; do
  if command -v brew >/dev/null && brew list --formula "$pkg" >/dev/null 2>&1; then
    echo "ok: $pkg installed"
  else
    run brew install "$pkg"
  fi
done

if [[ $dry -eq 1 ]]; then
  echo "dry-run: not inspecting the podman machine"
  run podman machine init --rootful --cpus 6 --memory 8192 --disk-size 120 "$machine"
  run podman machine start "$machine"
  exit 0
fi

# JSON output avoids Go-template quoting; the machine list shows Running/Rootful.
info="$(podman machine inspect "$machine" 2>/dev/null || true)"
if [[ -n "$info" ]]; then
  echo "ok: podman machine $machine exists"
  jq -e '.[0].Rootful == true' <<<"$info" >/dev/null ||
    echo "warning: machine $machine is not rootful; run 'podman machine set --rootful $machine'" >&2
else
  run podman machine init --rootful --cpus 6 --memory 8192 --disk-size 120 "$machine"
  info="$(podman machine inspect "$machine")"
fi

if jq -e '.[0].State == "running"' <<<"$info" >/dev/null; then
  echo "ok: machine running"
else
  run podman machine start "$machine"
fi

arch="$(podman run --rm --privileged registry.fedoraproject.org/fedora:44 uname -m 2>/dev/null || true)"
[[ "$arch" == aarch64 ]] || { echo "container arch is '$arch', expected aarch64" >&2; exit 1; }
echo "setup complete; register the runner by hand (step 4 of the doc)"
