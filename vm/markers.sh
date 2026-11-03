#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by vm/boot-test.sh and vm/install-test.sh: the guest marker protocol of docs/phases/phase-5.md
# (ZEEOS_SECUREBOOT, ZEEOS_HARDENING_CHECK/_OK/_FAIL). Bash 3.2 safe: no associative arrays, no mapfile.
# Without the ZEEOS_HARDENING_CHECK announce the harness checks nothing new.

# sb_guest LOG -> on | off | unreported (first "ZEEOS_SECUREBOOT enabled=<0|1>" line)
sb_guest() {
  case $(grep -aom1 '^ZEEOS_SECUREBOOT enabled=[01]' "$1" 2>/dev/null | sed 's/.*=//' || true) in
    1) echo on;; 0) echo off;; *) echo unreported;;
  esac
}

# hardening_wait LOG SECONDS PID: block until an OK or FAIL line shows up, the timeout runs out, or PID is gone.
hardening_wait() {
  local t=$SECONDS
  while (( SECONDS - t < $2 )); do
    grep -aq -e '^ZEEOS_HARDENING_OK' -e '^ZEEOS_HARDENING_FAIL' "$1" 2>/dev/null && return 0
    kill -0 "$3" 2>/dev/null || return 1
    sleep 2
  done
  return 1
}

# hardening_state LOG WAITED(0|1) -> none | ok | fail | timeout | unchecked
#   fail      a ZEEOS_HARDENING_FAIL line (wins over OK, announce or not)
#   ok        a ZEEOS_HARDENING_OK line
#   timeout   announced, no OK, and the caller waited (WAITED=1)
#   unchecked announced, no OK, caller did not wait (the boot had already failed)
#   none      no announce: nothing is checked
hardening_state() {
  if grep -aq '^ZEEOS_HARDENING_FAIL' "$1" 2>/dev/null; then echo fail
  elif grep -aq '^ZEEOS_HARDENING_OK' "$1" 2>/dev/null; then echo ok
  elif grep -aq '^ZEEOS_HARDENING_CHECK' "$1" 2>/dev/null; then
    if [ "$2" = 1 ]; then echo timeout; else echo unchecked; fi
  else echo none; fi
}

# hardening_msg STATE LOG -> human text for a junit failure
hardening_msg() {
  case $1 in
    fail) grep -aom1 '^ZEEOS_HARDENING_FAIL.*' "$2" | tr -d '\r' || true;;
    timeout) echo "ZEEOS_HARDENING_CHECK announced but no ZEEOS_HARDENING_OK";;
  esac
}

# hardening_worst A B -> the more serious of two states (fail > timeout > ok > unchecked > none)
hardening_worst() {
  local s
  for s in fail timeout ok unchecked none; do
    if [ "$1" = "$s" ] || [ "$2" = "$s" ]; then echo "$s"; return 0; fi
  done
  echo none
}
