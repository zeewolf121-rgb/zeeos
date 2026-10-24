# /build

Owner: `image-builder` (see docs/agents.md). Other agents: open an issue instead of editing here.

## Package pinning (ADR-0008)

`make iso ARCH=<arch>` uses only pinned inputs:

- **ISO packages.** `build/arch/<arch>/packages.lock` lists the full closure (`name epoch:version-release.arch sha256 source-rpm`)
  and the digest of the closure repo (a public GHCR image holding exactly those Fedora-signed RPMs). The closure
  repo is kiwi's only repo (`repos-pinned.xml`, gpgcheck on). After the build, `packages.list` must equal the lock or the build fails.
- **Build tools.** `build/arch/<arch>/tools-image.lock` pins the published build container by digest; `tools.lock` is its `rpm -qa`.
  Without a digest, `run.sh` builds the `Containerfile` locally and warns.
- **Opt-outs (developer only; CI and releases never set them).** `ZEEOS_UNPINNED=1` builds from the live mirrors;
  `ZEEOS_LOCAL_TOOLS=1` builds the tools image locally; `ZEEOS_CLOSURE_REBUILD=1` rebuilds the closure from the lock
  (sha256-checked, but superseded RPMs may be gone from mirrors and Koji).

### Refreshing the pins

```bash
podman login ghcr.io          # token with packages: write
make pin-packages ARCH=x86_64 # resolve in the build container, publish the closure, update the lock
make pin-packages ARCH=aarch64  # on an aarch64 host
build/container/publish.sh <arch>  # tools image + tools.lock, natively per arch
```

`PUBLISH=0 make pin-packages` resolves without publishing. An unchanged resolution leaves the lock untouched.
Each new GHCR package must be made public once by the owner; the publish scripts end with an anonymous pull and fail until then.
Lock format: `build/pin/lib.sh`. Scripts: `resolve.sh` (in container), `fetch.sh` (in container), `publish.sh` and `pull.sh` (host).

## ZeeOS-rebuilt RPMs (ADR-0011)

Fedora's `calamares` is rebuilt without `Requires: setxkbmap`. `build/rpms/<name>/source.lock` pins the Fedora SRPM
(NEVRA + sha256); `build/rpms/spec-delta.sh` holds the spec delta and fails if Fedora's spec no longer fits it.
Nothing there is per-arch; per-arch evidence lives in `build/arch/<arch>/rpms-buildroot/<name>.lock`.

```bash
make rpms-source-lock RPM=calamares ARCH=x86_64  # once per new SRPM: signature-checked download, writes the sha256
make rpms ARCH=x86_64      # native build in the pinned tools image -> out/x86_64/zeeos/, zeeos.lock, buildroot lock
make pin-packages ARCH=x86_64  # merges the rebuilds into packages.lock (origin zeeos-rebuild / zeeos-rebuild-src), publishes zeeos/
make iso ARCH=x86_64       # pulls the closure by digest; never rebuilds
ZEEOS_CLOSURE_REBUILD=1 make iso ARCH=x86_64   # rebuilds; rebuilt NEVRAs must equal the lock (bytes may differ)
```

- `SOURCE_DATE_EPOCH` for a rebuild is the newest changelog entry of the SRPM. A source.lock without a hash, or a
  tools image without a digest, makes `make rpms` stop as BLOCKED; `ZEEOS_ALLOW_UNPINNED_TOOLS=1` allows a
  development build whose output `pin-packages` refuses to lock.
- **Trust (interim, ADR-0011 item 5).** The closure's `zeeos/` directory is kiwi's second repo with
  `package_gpgcheck="false"`. Before kiwi runs, `build-iso.sh` checks every file in it against the lock's sha256 and fails
  on a tampered, missing or unlocked RPM. The Fedora closure repo keeps `package_gpgcheck="true"`. This mode is for the
  ISO build only; installed systems must never get a repo configured like this.
- Tests: `make test-build` (also part of `make lint`) runs fixtures only; it builds no RPM.

## Build container caching (opt-in)

`build/container/run.sh` honours these, all unset by default. The two image hooks apply only when
the tools image is built locally (no `TOOLS_IMAGE` in the arch's `tools-image.lock`, or
`ZEEOS_LOCAL_TOOLS=1`); a pinned tools image is always pulled.

- `ZEEOS_REUSE_BUILD_IMAGE=1`: skip `docker build` when `zeeos-build:<digest12>` already exists
  (CI can `docker load` a cached tarball first). The tag pins only the base image, so key the
  cache on `Containerfile` + `base-image.lock`.
- `ZEEOS_BUILD_CACHE_FROM=<ref>`: passed as `--cache-from`.
- `ZEEOS_KIWI_CACHE=<abs dir>`: mounted at `/var/cache/kiwi` to keep kiwi's package cache.
