#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Verdict of the required build-iso / boot-test summary jobs (#289).
# Usage: scripts/iso-summary-gate.sh <iso-inputs-changed> <changes-result> [<name>=<result> ...]
# - The path-selection job itself must have succeeded: if it failed or was cancelled, the flag is empty,
#   which must not read as "nothing changed".
# - If no ISO inputs changed: pass, saying so.
# - Otherwise every <name>=<result> must be "success". "skipped", "failure" and "cancelled" all fail,
#   so a skipped image job is never a pass (e.g. secureboot-chain=failure fails the summary).
set -uo pipefail
changed="${1:?usage: iso-summary-gate.sh <iso-inputs-changed> <changes-result> [name=result ...]}"
changes="${2:?usage: iso-summary-gate.sh <iso-inputs-changed> <changes-result> [name=result ...]}"
shift 2
if [[ "$changes" != success ]]; then
  echo "::error::the path-selection job (changes) was '$changes', so it is unknown whether ISO inputs changed"; exit 1
fi
if [[ "$changed" != true ]]; then echo "no ISO inputs changed"; exit 0; fi
bad=0
for pair in "$@"; do
  name="${pair%%=*}"; result="${pair#*=}"
  if [[ "$result" == success ]]; then echo "ok   $name: success"
  else echo "::error::$name was '${result:-unknown}' (needs success while ISO inputs changed)"; bad=1; fi
done
exit "$bad"
