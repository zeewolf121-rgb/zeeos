#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of scripts/ensure-podman-machine.sh against a fake podman: already running, stopped then
# started, start racing another job (start fails but the machine is up), another job mid-start, and a
# machine that never starts (must fail with ::error::). Usage: scripts/ensure-podman-machine-selftest.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
# The fake keeps its state in $FAKE_DIR/state. FAKE_MODE: start_ok | start_fail_but_up | start_fail | never_up
cat >"$tmp/podman" <<'FAKE'
#!/usr/bin/env bash
d="$FAKE_DIR"
case "$1 $2" in
  "machine inspect") cat "$d/state"; echo ;;
  "machine start")
    echo x >>"$d/starts"
    case "$FAKE_MODE" in
      start_ok) echo running >"$d/state" ;;
      start_fail_but_up) echo running >"$d/state"; echo "Error: machine already running" >&2; exit 125 ;;
      start_fail) echo "Error: boom" >&2; exit 125 ;;
      never_up) ;;
    esac ;;
  info*) [[ "$(cat "$d/state")" == running ]] ;;
esac
FAKE
chmod +x "$tmp/podman"

run() { # name initial-state mode expected-rc expected-output-regex [expected-start-count]
  local name="$1" init="$2" mode="$3" rc_want="$4" re="$5" starts_want="${6:-}"
  rm -rf "$tmp/d"; mkdir "$tmp/d"; echo "$init" >"$tmp/d/state"
  out="$(FAKE_DIR="$tmp/d" FAKE_MODE="$mode" PODMAN="$tmp/podman" ENSURE_TIMEOUT=4 ENSURE_POLL=1 "$here/ensure-podman-machine.sh" 2>&1)"; rc=$?
  starts=0; [[ -f "$tmp/d/starts" ]] && starts="$(wc -l <"$tmp/d/starts" | tr -d ' ')"
  if [[ $rc == "$rc_want" ]] && grep -Eq "$re" <<<"$out" && { [[ -z "$starts_want" ]] || [[ "$starts" == "$starts_want" ]]; }; then
    echo "ok   $name"
  else
    echo "FAIL $name: rc=$rc (want $rc_want), starts=$starts, output: $out"; fails=$((fails + 1))
  fi
}
run "already running: no start"          running  start_ok          0 'is running' 0
run "stopped: started"                   stopped  start_ok          0 'is ready' 1
run "start races another job (fails)"    stopped  start_fail_but_up 0 'is ready' 1
run "another job mid-start: no 2nd start" starting never_up         1 '::error::' 0
run "machine never starts: ::error::"    stopped  never_up          1 '::error::.*did not become ready'
run "start keeps failing: ::error::"     stopped  start_fail        1 '::error::.*did not become ready'
if (( fails == 0 )); then echo "all ensure-podman-machine self-tests passed"; else echo "$fails failed"; exit 1; fi
