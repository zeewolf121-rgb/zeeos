#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Make sure the Podman machine behind the self-hosted macOS ARM64 runners (docs/ci/macos-arm64-runner.md,
# #15) is running and answers `podman info`, starting it if needed. Run it before the first `podman`
# call of a job (#288: a stopped machine failed both aarch64 boot jobs with "connection refused").
#
# Two runner instances share one machine, so this is safe to run twice at once: it takes no lock, and
# a start that fails because the other job is starting (or already started) the machine is not an
# error. Only "the machine never became ready" is. It never stops the machine.
# Usage: scripts/ensure-podman-machine.sh
# Env: PODMAN_MACHINE (default zeeos), PODMAN (binary, default podman), ENSURE_TIMEOUT (seconds, default 240),
#      ENSURE_POLL (seconds between checks, default 3)
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
machine="${PODMAN_MACHINE:-zeeos}"
podman="${PODMAN:-podman}"
limit="${ENSURE_TIMEOUT:-240}"
poll="${ENSURE_POLL:-3}"

state() { "$podman" machine inspect "$machine" --format '{{.State}}' 2>/dev/null | head -n1 | tr -d '[:space:]'; }
ready() { [[ "$(state)" == running ]] && "$podman" info >/dev/null 2>&1; }

if ! command -v "$podman" >/dev/null 2>&1; then
  echo "::error::podman is not on PATH on this runner"; exit 1
fi
if ready; then echo "podman machine $machine is running"; exit 0; fi

echo "podman machine $machine is '$(state)'; starting it"
start=$SECONDS
deadline=$((SECONDS + limit))
next_start=$SECONDS
while (( SECONDS < deadline )); do
  if ready; then echo "podman machine $machine is ready after $((SECONDS - start)) s"; exit 0; fi
  # Start when stopped (or unknown); while another job has it 'starting' just wait. A stopped machine
  # is retried every 30 s. A failed start is not fatal: it usually means the other job won the race.
  if (( SECONDS >= next_start )) && [[ "$(state)" != running && "$(state)" != starting ]]; then
    out="$("$podman" machine start "$machine" 2>&1)" || echo "podman machine start: ${out//$'\n'/ } (continuing; waiting for the machine)"
    next_start=$((SECONDS + 30))
  fi
  sleep "$poll"
done
echo "::error::podman machine $machine did not become ready within ${limit} s (state: '$(state)'); start it on the runner with: podman machine start $machine"
exit 1
