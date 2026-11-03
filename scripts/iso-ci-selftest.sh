#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Regression tests for ISO-input path selection (scripts/iso-inputs.sh) and the summary verdict
# (scripts/iso-summary-gate.sh), #289. Offline. Usage: scripts/iso-ci-selftest.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

paths() { # name want file...
  local name="$1" want="$2"; shift 2
  local got; got="$(printf '%s\n' "$@" | "$here/iso-inputs.sh" 2>/dev/null)"
  if [[ "$got" == "$want" ]]; then ok "paths: $name"; else bad "paths: $name (got $got, want $want)"; fi
}
for f in build/arch/x86_64/config.xml build/stage-installer.sh desktop/live/overlay/etc/x.conf vm/boot-test.sh \
         Makefile .github/workflows/build-iso.yml .github/workflows/boot-test.yml \
         installer/calamares/settings.conf installer/modules/zee-plan/main.py \
         security/overlay/etc/sysctl.d/99.conf security/verify-secureboot-chain.sh \
         branding/wallpapers/zeeos/metadata.json tests/selftest.sh tests/fixtures/serial.log scripts/fetch-artifact.sh \
         scripts/iso-inputs.sh scripts/iso-summary-gate.sh scripts/iso-ci-selftest.sh; do
  paths "$f rebuilds" true "$f"
done
for f in docs/ARCHITECTURE.md README.md installer/README.md security/SECURE-BOOT.md tests/README.md build/README.md \
         scripts/ci-summary.sh .github/workflows/lint.yml .github/workflows/release.yml LICENSES/GPL-3.0-or-later.txt; do
  paths "$f does not rebuild" false "$f"
done
paths "mixed change rebuilds" true docs/a.md installer/tools/zee-plan.py
paths "empty diff does not rebuild" false

gate() { # name want-rc args...
  local name="$1" want="$2"; shift 2
  "$here/iso-summary-gate.sh" "$@" >/dev/null 2>&1; local rc=$?
  if [[ $rc == "$want" ]]; then ok "gate: $name"; else bad "gate: $name (rc $rc, want $want)"; fi
}
gate "nothing changed passes"                     0 false success
gate "all green passes"                           0 true success build=success secureboot-chain=success
gate "secureboot-chain failure fails"             1 true success build=success secureboot-chain=failure
gate "secureboot-chain skipped fails"             1 true success build=success secureboot-chain=skipped
gate "secureboot-chain cancelled fails"           1 true success build=success secureboot-chain=cancelled
gate "build failure fails"                        1 true success build=failure secureboot-chain=skipped
gate "boot failure fails"                         1 true success boot=failure
gate "boot success passes"                        0 true success boot=success
gate "failed path selection is not 'no change'"   1 '' failure
gate "cancelled path selection fails"            1 '' cancelled
gate "unchanged flag with failed selection fails" 1 false failure
# And through the real command line, the message names the failing chain job.
out="$("$here/iso-summary-gate.sh" true success build=success secureboot-chain=failure 2>&1)"
if grep -q '::error::secureboot-chain was .failure' <<<"$out"; then ok "gate: error names secureboot-chain"; else bad "gate: error names secureboot-chain ($out)"; fi
if (( fails == 0 )); then echo "all iso-ci self-tests passed"; else echo "$fails failed"; exit 1; fi
