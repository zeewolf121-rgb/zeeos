#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Stage release assets under their published names (docs/phases/phase-5.md "Release asset names"),
# refuse any asset >= 2 GiB (GitHub's per-asset limit) and write SHA256SUMS.
# Signing is not done here: release.yml signs SHA256SUMS with the CI key (ADR-0007).
set -euo pipefail

usage() {
  cat <<'USG'
Usage: release-assets.sh -v <version> -o <outdir> [-k <keysdir>] [-n] <file>...
  -v  release version without the leading "v" (e.g. 0.5.0-rc.1)
  -o  output directory (created)
  -k  directory with zeeos-ci.pub, zeeos-ci.pub.minisig, zeeos-root.pub
      (default: security/keys; env KEYS_DIR)
  -n  dry run: print what would happen, write nothing
Each <file> is classified by name: *x86_64*.iso, *aarch64*.iso or *aarch64*.utm.zip.
Output: zeeos-<ver>-x86_64.iso, zeeos-<ver>-aarch64.iso, zeeos-<ver>-aarch64.utm.zip,
the three key files and SHA256SUMS (covering the payload assets, not the key files).
USG
}

ver="" out="" dry=0
keys=${KEYS_DIR:-"$(dirname "$0")/../security/keys"}
while getopts 'v:o:k:nh' o; do
  case $o in
    v) ver=$OPTARG ;; o) out=$OPTARG ;; k) keys=$OPTARG ;; n) dry=1 ;;
    h) usage; exit 0 ;; *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ -n $ver && -n $out && $# -gt 0 ]] || { usage >&2; exit 2; }
[[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || { echo "bad version: $ver" >&2; exit 2; }

limit=$((2 * 1024 * 1024 * 1024))
declare -A src=()
for f in "$@"; do
  [[ -f $f ]] || { echo "ERROR: no such file: $f" >&2; exit 1; }
  b=${f##*/}
  case $b in
    *aarch64*.utm.zip) name=zeeos-$ver-aarch64.utm.zip ;;
    *x86_64*.iso)      name=zeeos-$ver-x86_64.iso ;;
    *aarch64*.iso)     name=zeeos-$ver-aarch64.iso ;;
    *) echo "ERROR: cannot classify $b (want *x86_64*.iso, *aarch64*.iso or *aarch64*.utm.zip)" >&2; exit 1 ;;
  esac
  [[ -z ${src[$name]:-} ]] || { echo "ERROR: two files map to $name: ${src[$name]} and $f" >&2; exit 1; }
  src[$name]=$f
done

fail=0
for name in "${!src[@]}"; do
  size=$(stat -L -c %s "${src[$name]}")   # -L: a symlinked input is measured by its target
  if ((size >= limit)); then
    echo "ERROR: $name is $size bytes, at or over the 2 GiB release asset limit (open a decision issue; do not work around)" >&2
    fail=1
  fi
done
((fail == 0)) || exit 1

keyfiles=(zeeos-ci.pub zeeos-ci.pub.minisig zeeos-root.pub)
for k in "${keyfiles[@]}"; do
  [[ -f $keys/$k ]] || { echo "ERROR: missing key file $keys/$k" >&2; exit 1; }
done

mapfile -t names < <(printf '%s\n' "${!src[@]}" | sort)
if ((dry)); then
  echo "dry run: nothing written to $out"
  for n in "${names[@]}"; do echo "  ${src[$n]} -> $out/$n"; done
  for k in "${keyfiles[@]}"; do echo "  $keys/$k -> $out/$k"; done
  echo "  $out/SHA256SUMS <- ${names[*]}"
  exit 0
fi

mkdir -p "$out"
for n in "${names[@]}"; do cp -- "${src[$n]}" "$out/$n"; done
for k in "${keyfiles[@]}"; do cp -- "$keys/$k" "$out/$k"; done
(cd "$out" && sha256sum -- "${names[@]}" >SHA256SUMS)
echo "staged ${#names[@]} assets in $out"
