# Handoff: #176 installer image wiring (P4-2 follow-up)
- Goal: ship Calamares config, branding and zee-* modules in the ISO root
- Done: build/stage-installer.sh (skips absent sources), called from build/build-iso.sh; Makefile lint runs installer tests and zee-plan
- Next: full ISO build once #240 is merged; ci-engineer to confirm PyYAML on the lint runner
- Blockers: none
- Files touched: build/stage-installer.sh, build/build-iso.sh, Makefile
- Last green commit / CI run: see PR
