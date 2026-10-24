#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Apply the ZeeOS spec delta for one package to <spec> in place (ADR-0011). Fails if the delta no
# longer applies, so a new Fedora spec can never be rebuilt silently with a different shape.
# Usage: build/rpms/spec-delta.sh <name> <spec>
set -euo pipefail
name="${1:?usage: spec-delta.sh <name> <spec>}"
spec="${2:?usage: spec-delta.sh <name> <spec>}"
[[ -f "$spec" ]] || { echo "no spec $spec" >&2; exit 2; }

# expect_one <description> <grep -E pattern>: the pattern must match exactly one line.
expect_one() {
  local n; n="$(grep -cE "$2" "$spec" || true)"
  [[ "$n" == 1 ]] || { echo "spec delta for $name no longer applies: $1 matches $n lines (want 1)" >&2; exit 1; }
}
# Release: <N>%{?dist}  ->  <N>.zeeos1%{?dist}
add_release_marker() {
  local pat='^Release:[[:space:]]*[0-9]+%[{][?]dist[}][[:space:]]*$'
  expect_one "Release line" "$pat"
  sed -i -E 's/^(Release:[[:space:]]*[0-9]+)%[{][?]dist[}][[:space:]]*$/\1.zeeos1%{?dist}/' "$spec"
}

case "$name" in
  calamares)
    # Drop the X11-only setxkbmap dependency; it sits outside every %ifarch. Nothing else changes.
    expect_one "Requires: setxkbmap" '^Requires:[[:space:]]+setxkbmap[[:space:]]*$'
    sed -i -E '/^Requires:[[:space:]]+setxkbmap[[:space:]]*$/d' "$spec"
    add_release_marker
    ;;
  sddm)
    # Only the release marker: the X11 removal is the `--without x11` bcond in source.lock's RPMBUILD_OPTS.
    add_release_marker
    ;;
  *) echo "no spec delta defined for $name" >&2; exit 2 ;;
esac
