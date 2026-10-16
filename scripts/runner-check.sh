#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Checks the macOS ARM64 runner: rootful podman, aarch64 Fedora 44 container,
# loop devices, QEMU with HVF. Prints a markdown table to $GITHUB_STEP_SUMMARY
# when set. Exits non-zero if any check fails.
# The check functions are invoked indirectly through check().
# shellcheck disable=SC2317
set -uo pipefail
fail=0
rows=""
check() {
  local name="$1" out; shift
  if out="$("$@" 2>&1)"; then
    rows+="| $name | pass |"$'\n'
  else
    rows+="| $name | **FAIL** |"$'\n'; fail=1; echo "$name: $out" >&2
  fi
}
img=registry.fedoraproject.org/fedora:44
rootful() { podman info --format json | jq -e '.host.security.rootless == false' >/dev/null; }
arch() { [[ "$(podman run --rm "$img" uname -m)" == aarch64 ]]; }
loop() { podman run --rm --privileged "$img" sh -c 'ls /dev/loop-control && losetup -f'; }
hvf() { [[ "$(sysctl -n kern.hv_support)" == 1 ]]; }
qemu() { qemu-system-aarch64 -accel help | grep -qx hvf; }
check "podman rootful" rootful
check "fedora 44 aarch64 container" arch
check "loop devices" loop
check "HVF supported" hvf
check "qemu-system-aarch64 hvf accel" qemu
out="### runner-check"$'\n\n'"| check | result |"$'\n'"|---|---|"$'\n'"$rows"
printf '%s\n' "$out"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$out" >> "$GITHUB_STEP_SUMMARY"
exit $fail
