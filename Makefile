# SPDX-License-Identifier: GPL-3.0-or-later
ARCH ?= x86_64
SECUREBOOT ?= on
.PHONY: iso iso-host pin-container reproducible boot-test lint
iso:
	build/container/run.sh $(ARCH)
iso-host:
	build/build-iso.sh $(ARCH)
pin-container:
	build/container/pin.sh
reproducible:
	build/check-reproducible.sh $(ARCH)
boot-test:
	ARCH=$(ARCH) SECUREBOOT=$(SECUREBOOT) $(if $(ISO),ISO=$(ISO)) $(if $(OUT),OUT=$(OUT)) vm/boot-test.sh
lint:
	shellcheck -x scripts/*.sh scripts/autopilot/*.sh build/*.sh build/common/*.sh build/container/*.sh
	yamllint -d relaxed .github
	actionlint
	reuse lint
	scripts/sync-agent-docs.sh --check
	scripts/autopilot/selftest.sh
