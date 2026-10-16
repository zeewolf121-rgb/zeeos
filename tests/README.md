# /tests

Owner: `vm-integrator` (see docs/agents.md). Other agents: open an issue instead of editing here.

## Status

`tests/selftest.sh` checks the harness offline (`DRY_RUN`, argument validation); it does not boot anything.
Real boot results come only from CI runs of `vm/boot-test.sh`. Not yet implemented: fake Windows seed disk and
checksum tests, aarch64 SB-on key enrollment.
