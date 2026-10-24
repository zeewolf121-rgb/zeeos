#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Rebuild the Fedora SRPMs listed under build/rpms/*/ natively on this arch (ADR-0011).
# Runs INSIDE the build container as root: `make rpms ARCH=<arch>` calls it through run.sh.
#   1. fetch the SRPM by NEVRA, check it against source.lock's sha256 and Fedora's signature;
#   2. apply the spec delta (spec-delta.sh), install BuildRequires, run rpmbuild with
#      SOURCE_DATE_EPOCH = the newest changelog entry of the SRPM;
#   3. write <out>/zeeos/*.rpm (binary RPMs + the rebuilt SRPM), <out>/zeeos.lock (lock lines for
#      pin-packages) and the buildroot manifest build/arch/<arch>/rpms-buildroot/<name>.lock.
# ZEEOS_RPMS_ONLY=<name>   build just that package.
# ZEEOS_RPMS_CHECK=1       rebuild and compare identities with packages.lock; writes nothing into
#                          the checkout and exits 1 on a mismatch (rpm bytes may differ, names may not).
# Usage: build/rpms/build.sh <arch> [out-dir]
set -euo pipefail
arch="${1:?usage: build.sh <arch> [out-dir]}"
# shellcheck source=build/rpms/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
out="${2:-$PIN_ROOT/out/$arch}"
check="${ZEEOS_RPMS_CHECK:-0}"
tools_pinned="${ZEEOS_TOOLS_PINNED:-0}"

names=()
if [[ -n "${ZEEOS_RPMS_ONLY:-}" ]]; then names=("$ZEEOS_RPMS_ONLY")
else for f in "$RPMS_DIR"/*/source.lock; do names+=("$(basename "$(dirname "$f")")"); done; fi
(( ${#names[@]} )) || { echo "no packages under $RPMS_DIR" >&2; exit 1; }

# Every lock must be populated before anything is downloaded or installed: never guess a hash.
for n in "${names[@]}"; do
  rpms_load_source "$n"
  [[ "$SRPM_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "BLOCKED: build/rpms/$n/source.lock has no SRPM_SHA256. Run 'make rpms-source-lock RPM=$n ARCH=$arch'" >&2
    echo "         to record it from a signed download; it is never guessed." >&2
    exit 1; }
done
[[ "$(uname -m)" == "$arch" ]] || { echo "build natively: host is $(uname -m), not $arch (no emulation)" >&2; exit 2; }
if [[ "$tools_pinned" != 1 ]]; then
  echo "WARNING: build tools image is not digest-pinned: this build is for development only and will not be locked" >&2
fi

rm -rf "$out/zeeos" "$out/zeeos.lock"; mkdir -p "$out/zeeos"
lockout="$out/zeeos.lock"
{
  echo "# SPDX-License-""Identifier: GPL-3.0-or-later"
  echo "# ZeeOS rebuilds for $arch (ADR-0011), written by build/rpms/build.sh. Columns as in packages.lock."
  echo "# tools-image=$([[ "$tools_pinned" == 1 ]] && echo pinned || echo unpinned)"
} >"$lockout"

for n in "${names[@]}"; do
  rpms_load_source "$n"
  work="$(mktemp -d)"
  sha="$(rpms_download_srpm "$work/dl")"
  [[ "$sha" == "$SRPM_SHA256" ]] || { echo "$SRPM sha256 $sha does not match build/rpms/$n/source.lock ($SRPM_SHA256)" >&2; exit 1; }
  pin_check_signatures "$work/dl/$SRPM"

  # Deterministic time: the newest changelog entry of the Fedora source.
  SOURCE_DATE_EPOCH="$(rpm -qp --qf '[%{CHANGELOGTIME}\n]' "$work/dl/$SRPM" | head -1)"
  [[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || { echo "no changelog time in $SRPM" >&2; exit 1; }
  export SOURCE_DATE_EPOCH

  top="$work/top"; mkdir -p "$top"
  rpm --define "_topdir $top" -i "$work/dl/$SRPM"
  spec="$top/SPECS/$n.spec"
  [[ -f "$spec" ]] || { echo "SRPM has no SPECS/$n.spec" >&2; exit 1; }
  bash "$RPMS_DIR/spec-delta.sh" "$n" "$spec"
  dnf5 -y builddep "$spec"

  # Buildroot manifest: everything installed at build time, so the environment is reviewable.
  manifest="$work/rpms-buildroot.lock"
  {
    echo "# SPDX-License-""Identifier: GPL-3.0-or-later"
    echo "# rpm -qa of the build container while building $n on $arch (written by build/rpms/build.sh)."
    rpm -qa --qf '%{NAME}|%{EPOCHNUM}|%{VERSION}|%{RELEASE}|%{ARCH}\n' | pin_identities
  } >"$manifest"

  # shellcheck disable=SC2086  # RPMBUILD_OPTS is a deliberate word list from the lock
  rpmbuild -ba $RPMBUILD_OPTS --define "_topdir $top" \
    --define 'source_date_epoch_from_changelog 1' --define 'use_source_date_epoch_as_buildtime 1' \
    --define 'clamp_mtime_to_source_date_epoch 1' "$spec"

  # Debug subpackages are never installed on the ISO: keep them out of the closure.
  while IFS= read -r f; do
    case "$(basename "$f")" in *-debuginfo-*|*-debugsource-*) continue ;; esac
    cp "$f" "$out/zeeos/"
    # %{ARCH} of an SRPM is the build arch, not "src": name source RPMs by their file suffix.
    sfx="$(rpm -qp --qf '%{ARCH}' "$f")"; [[ "$f" == *.src.rpm ]] && sfx=src
    evra="$(rpm -qp --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' "$f").$sfx"
    [[ "$evra" == *.zeeos* ]] || { echo "built $f has no .zeeos release marker" >&2; exit 1; }
    pn="$(rpm -qp --qf '%{NAME}' "$f")"
    origin=zeeos-rebuild; [[ "$f" == *.src.rpm ]] && origin=zeeos-rebuild-src
    echo "$pn $evra $(sha256sum "$f" | cut -d' ' -f1) $n $origin" >>"$lockout"
  done < <(find "$top/RPMS" "$top/SRPMS" -name '*.rpm' | LC_ALL=C sort)

  if (( ! check )) && [[ "$tools_pinned" == 1 ]]; then
    mkdir -p "$PIN_ROOT/build/arch/$arch/rpms-buildroot"
    cp "$manifest" "$PIN_ROOT/build/arch/$arch/rpms-buildroot/$n.lock"
  fi
  rm -rf "$work"
done

createrepo_c --quiet "$out/zeeos"
if (( check )); then
  # Identities (not bytes) must match the lock's zeeos lines.
  lock="$(pin_lock "$arch")"
  # Every locked package must come out of the rebuild with the same identity. Rebuilt subpackages
  # the lock does not name (not installed on the ISO) are fine; they never reach the closure.
  want="$(pin_lock_lines "$lock" zeeos-rebuild | awk '{ print $1, $2 }' | LC_ALL=C sort)"
  got="$(pin_lock_lines "$lockout" zeeos-rebuild | awk '{ print $1, $2 }' | LC_ALL=C sort)"
  missing="$(LC_ALL=C comm -23 <(echo "$want") <(echo "$got"))"
  if [[ -n "$missing" ]]; then
    echo "rebuilt ZeeOS RPMs do not match the identities locked in $lock; not reproduced:" >&2
    echo "$missing" >&2
    exit 1
  fi
  echo "rebuilt ZeeOS RPM identities match $lock"
fi
echo "ZeeOS RPMs for $arch in $out/zeeos ($(grep -vc '^#' "$lockout") files); lock fragment $lockout"
