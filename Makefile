# SPDX-License-Identifier: GPL-3.0-or-later
ARCH ?= x86_64
SECUREBOOT ?= on
.PHONY: iso boot-test lint
iso:
	build/build-iso.sh $(ARCH)
boot-test:
	@echo "make boot-test ARCH=$(ARCH) SECUREBOOT=$(SECUREBOOT): not implemented yet (Phase 1, agent:vm-integrator)" >&2; exit 2
lint:
	shellcheck -x scripts/*.sh scripts/autopilot/*.sh build/*.sh build/common/*.sh
	yamllint -d relaxed .github
	actionlint
	reuse lint
	scripts/sync-agent-docs.sh --check
	scripts/autopilot/selftest.sh
