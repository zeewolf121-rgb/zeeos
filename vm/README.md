# /vm

Owner: `vm-integrator` (see docs/agents.md). Other agents: open an issue instead of editing here.

## Boot harness

```bash
ARCH=x86_64 SECUREBOOT=on ISO=out/zeeos.iso vm/boot-test.sh
DRY_RUN=1 vm/boot-test.sh      # print the QEMU command only
```

Env: `ARCH`, `SECUREBOOT=on|off`, `ISO`, `DISK` (seed image, attached via a qcow2 overlay so it is never modified),
`OUT`, `TIMEOUT` (default 600 s), `MARKER` (default `ZEEOS_DESKTOP_READY`: the string the in-guest
desktop-ready unit must print on the serial console; P1-9 must agree on it).

Theme check (phase-2 marker protocol): if the guest prints `ZEEOS_THEME_CHECK`, the harness also requires
`ZEEOS_THEME_OK` and `ZEEOS_DARK_READY` (fails on `ZEEOS_THEME_FAIL` or after `THEME_TIMEOUT`, default 600 s per
marker), and screenshots after each (`screenshot-light.ppm`, `screenshot-dark.ppm`; `screenshot.ppm` is still taken
at the desktop-ready marker). Without `ZEEOS_THEME_CHECK` nothing changes. junit properties: `theme_check`,
`boot_seconds`, `idle_total_kb`/`idle_available_kb`/`idle_used_kb` (from `ZEEOS_MEM`), and `light_dark_diff_pct`
(`imgdiff.py`, report-only).

Outputs in `OUT`: `serial.log`, `screenshot.ppm` (QMP screendump), `junit.xml`, `accel` (`kvm`/`hvf`/`tcg`).

SB on uses Microsoft-keys enrolled OVMF vars (Fedora edk2 `OVMF_VARS.secboot.fd`); Fedora and Debian/Ubuntu
firmware paths are probed. aarch64 SB-on needs an AAVMF vars file with keys enrolled; if none is found the run
falls back to the stock vars and is not a true Secure Boot test.

`make boot-test` still needs wiring to this script (the Makefile is outside this agent's scope).
