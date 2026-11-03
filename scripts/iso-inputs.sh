#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Decide whether a change touches ISO inputs (#289). Reads changed file names on stdin, one per line,
# prints "true" or "false", prints the matching files on stderr. build-iso.yml uses it to decide whether
# the build/boot matrix must run; anything that ends up in the image or changes how it is built/tested
# counts, except Markdown. Usage: git diff --name-only BASE...HEAD | scripts/iso-inputs.sh
set -uo pipefail
# build/ (image description, package locks, stage-installer), desktop/ (live overlay), security/
# (overlay, verify-secureboot-chain.sh), installer/ (Calamares config and zee-* modules), branding/
# (wallpapers), tests/ and vm/ (boot harness), the Makefile, the fetch helper the boot job runs, and
# the build/boot workflows themselves.
pattern='^(build/|desktop/|installer/|security/|branding/|tests/|vm/|Makefile$|scripts/fetch-artifact\.sh$|\.github/workflows/(build-iso|boot-test)\.yml$)'
hits="$(grep -E "$pattern" | grep -v '\.md$' || true)"
if [[ -n "$hits" ]]; then echo "$hits" >&2; echo true; else echo false; fi
