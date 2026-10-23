# SPDX-License-Identifier: GPL-3.0-or-later
ARCH ?= x86_64
SECUREBOOT ?= on
# The ISO that `make iso ARCH=…` writes; override with ISO=<path>.
ISO ?= $(firstword $(wildcard out/$(ARCH)/image/*.iso))
.PHONY: iso iso-host pin-container pin-packages reproducible boot-test lint
iso:
	build/container/run.sh $(ARCH)
iso-host:
	build/build-iso.sh $(ARCH)
pin-container:
	build/container/pin.sh
# Refresh build/arch/$(ARCH)/packages.lock (resolve in the build container, publish the closure repo).
# Needs network and `podman login ghcr.io` with packages: write. PUBLISH=0 resolves only.
pin-packages:
	ZEEOS_UNPINNED=1 ZEEOS_ENTRY=build/pin/resolve.sh build/container/run.sh $(ARCH)
	$(if $(filter 0,$(PUBLISH)),,build/pin/publish.sh $(ARCH))
reproducible:
	build/check-reproducible.sh $(ARCH)
boot-test:
	ARCH=$(ARCH) SECUREBOOT=$(SECUREBOOT) $(if $(ISO),ISO=$(ISO)) $(if $(OUT),OUT=$(OUT)) vm/boot-test.sh
lint:
	shellcheck -x scripts/*.sh scripts/autopilot/*.sh build/*.sh build/common/*.sh build/container/*.sh build/pin/*.sh security/*.sh
	yamllint -d relaxed .github
	actionlint
	reuse lint
	scripts/sync-agent-docs.sh --check
	scripts/autopilot/selftest.sh
	for t in installer/modules/*/tests; do [ -d "$$t" ] || continue; python3 -m unittest discover -s "$$t" || exit 1; done
