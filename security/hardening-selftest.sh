#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline checks of security/overlay/usr/libexec/zeeos-hardening-check (P5-2): fake /sys, /etc and /proc trees
# plus stub getenforce, systemctl, firewall-cmd, sshd and mokutil that answer from files under the tree.
# shellcheck disable=SC2016  # the stub bodies expand when they run, not here
set -euo pipefail
cd "$(dirname "$0")/.."
chk=security/overlay/usr/libexec/zeeos-hardening-check
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Stubs: each prints state from $ROOT/st/<name>. Units are listed in st/active and st/enabled.
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$tmp/$1"; chmod +x "$tmp/$1"; }
stub getenforce 'cat "$ROOT/st/selinux"'
stub systemctl 'case $1 in is-active) grep -qx "$3" "$ROOT/st/active";; is-enabled) grep -qx "$3" "$ROOT/st/enabled";; esac'
stub firewall-cmd 'case $* in
  *--get-default-zone*) cat "$ROOT/st/fw-zone";;
  *--permanent*--get-target*) cat "$ROOT/st/fw-target";;
  *--get-target*) echo "stub: --get-target needs --permanent" >&2; exit 2;;
  *--list-services*) cat "$ROOT/st/fw-services";;
  *--list-ports*) cat "$ROOT/st/fw-ports";;
  *--query-masquerade*) echo no;;
  *) : ;;
esac'
stub sshd 'cat "$ROOT/st/sshd-T"'
stub mokutil 'exit 1'

# mk <name> [key=value overrides]: a healthy installed system, then overrides.
mk() {
  local r=$tmp/$1; shift
  mkdir -p "$r/st" "$r/etc/selinux" "$r/proc" "$r/sys/firmware/efi/efivars" "$r/sys/class/tty"
  echo Enforcing > "$r/st/selinux"; echo SELINUX=enforcing > "$r/etc/selinux/config"
  echo "quiet root=live:x" > "$r/proc/cmdline"
  printf 'firewalld.service\ndnf5-automatic.timer\n' > "$r/st/active"
  echo dnf5-automatic.timer > "$r/st/enabled"
  echo public > "$r/st/fw-zone"; echo default > "$r/st/fw-target"
  echo "dhcpv6-client mdns" > "$r/st/fw-services"; : > "$r/st/fw-ports"
  : > "$r/st/sshd-T"
  printf '\007\000\000\000\001' > "$r/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  local kv; for kv; do
    case $kv in
      selinux=permissive) echo Permissive > "$r/st/selinux";;
      selinux-config=permissive) echo SELINUX=permissive > "$r/etc/selinux/config";;
      cmdline=*) echo "${kv#cmdline=}" > "$r/proc/cmdline";;
      fw=down) echo dnf5-automatic.timer > "$r/st/active";;
      fw-service=*) echo "dhcpv6-client mdns ${kv#fw-service=}" > "$r/st/fw-services";;
      fw-port) echo 8080/tcp > "$r/st/fw-ports";;
      sshd=keyonly) echo sshd.service >> "$r/st/active"; printf 'passwordauthentication no\nkbdinteractiveauthentication no\n' > "$r/st/sshd-T";;
      sshd=password) echo sshd.service >> "$r/st/active"; printf 'passwordauthentication yes\nkbdinteractiveauthentication no\n' > "$r/st/sshd-T";;
      timer=off) : > "$r/st/enabled"; echo firewalld.service > "$r/st/active";;
      timer=live-active) ;;
      sb=off) printf '\007\000\000\000\000' > "$r/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c";;
      sb=none) rm -rf "$r/sys/firmware/efi";;
      *) fail "bad override $kv";;
    esac
  done
  echo "$r"
}

# run <name> <pass|fail> <pattern...>: pattern must appear in the output. Overrides come from OVR.
run() {
  local name=$1 want=$2 r out rc=0; shift 2
  # shellcheck disable=SC2086
  r=$(mk "$name" ${OVR:-})
  out=$(ROOT=$r DRY_RUN=1 PATH="$tmp:$PATH" GETENFORCE=getenforce SYSTEMCTL=systemctl FIREWALL_CMD=firewall-cmd \
        SSHD=sshd MOKUTIL=mokutil bash "$chk" 2>&1) || rc=$?
  { [ "$want" = pass ] && [ "$rc" != 0 ]; } && fail "$name: expected pass, got: $out"
  { [ "$want" = fail ] && [ "$rc" = 0 ]; } && fail "$name: expected fail, got: $out"
  for p in "$@"; do grep -qF -- "$p" <<<"$out" || fail "$name: output lacks '$p': $out"; done
  if [ "$want" = fail ]; then ! grep -q ZEEOS_HARDENING_OK <<<"$out" || fail "$name: OK printed with a failure"; fi
}
ok() { echo "ok: $1"; }

OVR='' run installed-ok pass 'ZEEOS_SECUREBOOT enabled=1' \
  'ZEEOS_HARDENING_OK selinux=enforcing firewall=firewalld inbound=deny sshd=off autoupdate=on'; ok installed
OVR='cmdline=rd.live.image' run live-ok pass \
  'ZEEOS_HARDENING_OK selinux=enforcing firewall=firewalld inbound=deny sshd=off autoupdate=live-off'; ok live-off
OVR='timer=off cmdline=rd.live.image' run live-timer-off pass 'autoupdate=live-off'; ok live-timer-inactive
OVR='sb=off' run sb-off pass 'ZEEOS_SECUREBOOT enabled=0' 'ZEEOS_HARDENING_OK'; ok sb-off
OVR='sb=none' run sb-bios pass 'ZEEOS_SECUREBOOT enabled=0'; ok sb-no-efivars
OVR='sshd=keyonly' run ssh-key pass 'sshd=keyonly'; ok sshd-keyonly
OVR='sshd=password' run ssh-pw fail 'ZEEOS_HARDENING_FAIL sshd:'; ok sshd-password
OVR='selinux=permissive' run se-perm fail 'ZEEOS_HARDENING_FAIL selinux: getenforce'; ok selinux-permissive
OVR='selinux-config=permissive' run se-cfg fail 'ZEEOS_HARDENING_FAIL selinux: /etc/selinux/config'; ok selinux-config
OVR='cmdline=enforcing=0' run se-cmd fail 'ZEEOS_HARDENING_FAIL selinux: selinux=0'; ok selinux-cmdline
OVR='fw=down' run fw-down fail 'ZEEOS_HARDENING_FAIL firewall: firewalld.service is not active'; ok firewall-down
OVR='fw-service=ssh' run fw-ssh fail 'ZEEOS_HARDENING_FAIL firewall: public allows service ssh'; ok firewall-extra-service
OVR='fw-port' run fw-port fail 'ZEEOS_HARDENING_FAIL firewall: public has ports'; ok firewall-open-port
OVR='timer=off' run au-off fail 'ZEEOS_HARDENING_FAIL autoupdate:'; ok autoupdate-missing-installed
# live session with the timer running is a failure
r=$(mk live-active cmdline=rd.live.image); echo dnf5-automatic.timer >> "$r/st/active"
rc=0; out=$(ROOT=$r DRY_RUN=1 PATH="$tmp:$PATH" bash "$chk" 2>&1) || rc=$?
{ [ "$rc" != 0 ] && grep -q 'FAIL autoupdate: .* active in the live' <<<"$out"; } || fail "live-active: $out"; ok live-timer-running

out=$(DRY_RUN=1 bash "$chk" announce); [ "$out" = ZEEOS_HARDENING_CHECK ] || fail "announce: $out"; ok announce

# overlay drop-ins carry the ADR-0012 values
grep -qx 'ConditionKernelCommandLine=!rd.live.image' security/overlay/usr/lib/systemd/system/dnf5-automatic.timer.d/50-zeeos-live-off.conf \
  || fail "live-off drop-in"
grep -qx 'reboot = never' security/overlay/etc/dnf/automatic.conf || fail "automatic.conf reboot"
grep -qx 'upgrade_type = security' security/overlay/etc/dnf/automatic.conf || fail "automatic.conf type"
grep -qx 'PasswordAuthentication no' security/overlay/etc/ssh/sshd_config.d/40-zeeos-keyonly.conf || fail "sshd drop-in"
! grep -q 'name="ssh"' security/overlay/etc/firewalld/zones/public.xml || fail "public.xml allows ssh"
python3 -I -c 'import sys, xml.dom.minidom as m; m.parse(sys.argv[1])' security/overlay/etc/firewalld/zones/public.xml
ok overlay-files
echo "hardening selftest ok"
