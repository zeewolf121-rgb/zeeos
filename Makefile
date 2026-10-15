# SPDX-License-Identifier: GPL-3.0-or-later
ARCH ?= x86_64
SECUREBOOT ?= on
.PHONY: iso boot-test lint
iso:
	@echo "make iso ARCH=$(ARCH): not implemented yet (Phase 1, agent:image-builder)" >&2; exit 2
boot-test:
	@echo "make boot-test ARCH=$(ARCH) SECUREBOOT=$(SECUREBOOT): not implemented yet (Phase 1, agent:vm-integrator)" >&2; exit 2
lint:
	shellcheck scripts/*.sh
	yamllint -d relaxed .github
	reuse lint
	scripts/sync-agent-docs.sh --check
