#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Check that the self-hosted macOS ARM64 runner (docs/ci/macos-arm64-runner.md, #15) can take the
# aarch64 build and boot jobs. Prints one "ok|FAIL|warn <check>: <detail>" line per check and
# exits 1 if any required check fails. Read-only apart from a throwaway loop file in the container.
# Usage: scripts/runner-check.sh   (env: PODMAN_MACHINE, default zeeos)
set -uo pipefail
machine="${PODMAN_MACHINE:-zeeos}"
fails=0
ok() { echo "ok   $1: $2"; }
bad() { echo "FAIL $1: $2"; fails=$((fails + 1)); }
warn() { echo "warn $1: $2"; }

if [[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]]; then ok host "$(sw_vers -productVersion 2>/dev/null) arm64"
else bad host "$(uname -s)/$(uname -m), want Darwin/arm64"; fi

for t in podman qemu-system-aarch64 jq gh; do
  if command -v "$t" >/dev/null; then ok tool "$t"; else bad tool "$t not on PATH"; fi
done

state="$(podman machine inspect "$machine" --format '{{.State}}' 2>/dev/null || true)"
if [[ "$state" == running ]]; then ok podman-machine "$machine running"; else bad podman-machine "$machine is '${state:-missing}'"; fi
rootful="$(podman machine inspect "$machine" --format '{{.Rootful}}' 2>/dev/null || true)"
if [[ "$rootful" == true ]]; then ok podman-rootful "$machine"; else bad podman-rootful "$machine is not rootful"; fi

arch="$(podman run --rm registry.fedoraproject.org/fedora:44 uname -m 2>/dev/null || true)"
if [[ "$arch" == aarch64 ]]; then ok container "fedora:44 is $arch"; else bad container "fedora:44 uname -m gave '${arch:-nothing}'"; fi

# kiwi-ng attaches the image through a loop device inside the privileged build container.
loop="$(podman run --rm --privileged registry.fedoraproject.org/fedora:44 bash -c \
  'truncate -s 16M /tmp/l.img && d=$(losetup -f --show /tmp/l.img) && echo "$d" && losetup -d "$d"' 2>&1 | tail -n1)"
if [[ "$loop" == /dev/loop* ]]; then ok loop-device "$loop attached and detached"; else bad loop-device "losetup: ${loop:-no output}"; fi

# HVF: boot the plain AArch64 UEFI firmware headless for a few seconds and look for its banner.
share="$(dirname "$(command -v qemu-system-aarch64 2>/dev/null || echo /x/bin/q)")/../share/qemu"
code="$share/edk2-aarch64-code.fd"
if [[ -r "$code" ]]; then
  out="$( (qemu-system-aarch64 -accel hvf -machine virt -cpu host -m 512 -bios "$code" -nographic \
    -serial stdio -monitor none -display none & q=$!; sleep 8; kill "$q") 2>&1 | tr -d '\r' | head -c 4000)"
  if grep -qiE 'UEFI|EDK II|BdsDxe' <<<"$out"; then ok qemu-hvf "UEFI firmware runs under HVF"
  else bad qemu-hvf "no firmware output under HVF: $(head -c 200 <<<"$out")"; fi
else
  bad qemu-hvf "no $code"
fi

# The aarch64 sb-on cell needs a Secure Boot AAVMF build plus Microsoft-keys vars (vm/boot-test.sh).
sb=""
for f in /usr/share/AAVMF/AAVMF_CODE.ms.fd /usr/share/AAVMF/AAVMF_CODE.secboot.fd "$share/edk2-aarch64-secure-code.fd"; do
  [[ -r "$f" ]] && { sb="$f"; break; }
done
if [[ -n "$sb" ]]; then ok sb-firmware "$sb"; else warn sb-firmware "no aarch64 Secure Boot firmware; the sb-on cell can't move to this runner yet"; fi

echo "runner-check: $fails required check(s) failed"
(( fails == 0 ))
