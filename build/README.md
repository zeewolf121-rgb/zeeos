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
