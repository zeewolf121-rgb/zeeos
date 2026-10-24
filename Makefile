# SPDX-License-Identifier: GPL-3.0-or-later
ARCH ?= x86_64
SECUREBOOT ?= on
# The ISO that `make iso ARCH=…` writes; override with ISO=<path>.
ISO ?= $(firstword $(wildcard out/$(ARCH)/image/*.iso))
.PHONY: iso iso-host pin-container pin-packages rpms rpms-source-lock test-build reproducible boot-test lint
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
# ZeeOS rebuilds of Fedora SRPMs (ADR-0011): native per arch, in the digest-pinned tools image.
# Writes out/$(ARCH)/zeeos/ and build/arch/$(ARCH)/rpms-buildroot/. RPM=<name> builds one package.
# Blocked (not skipped) while build/arch/$(ARCH)/tools-image.lock or a source.lock hash is empty.
rpms:
	ZEEOS_RPMS_ONLY=$(RPM) ZEEOS_ENTRY=build/rpms/build.sh build/container/run.sh $(ARCH)
# Record a Fedora SRPM's sha256 in build/rpms/$(RPM)/source.lock from a signature-checked download.
rpms-source-lock:
	ZEEOS_RPMS_ONLY=$(RPM) ZEEOS_ENTRY=build/rpms/lock-source.sh build/container/run.sh $(ARCH)
test-build:
	bash build/tests/zeeos-closure-test.sh
reproducible:
	build/check-reproducible.sh $(ARCH)
boot-test:
	ARCH=$(ARCH) SECUREBOOT=$(SECUREBOOT) $(if $(ISO),ISO=$(ISO)) $(if $(OUT),OUT=$(OUT)) vm/boot-test.sh
lint:
	shellcheck -x scripts/*.sh scripts/autopilot/*.sh build/*.sh build/common/*.sh build/container/*.sh build/pin/*.sh build/rpms/*.sh build/tests/*.sh security/*.sh
	yamllint -d relaxed .github
	actionlint
	reuse lint
	scripts/sync-agent-docs.sh --check
	scripts/autopilot/selftest.sh
	bash build/tests/zeeos-closure-test.sh
