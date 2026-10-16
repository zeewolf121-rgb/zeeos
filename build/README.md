# /build

Owner: `image-builder` (see docs/agents.md). Other agents: open an issue instead of editing here.

## Build container caching (opt-in)

`build/container/run.sh` honours these, all unset by default:

- `ZEEOS_REUSE_BUILD_IMAGE=1`: skip `docker build` when `zeeos-build:<digest12>` already exists
  (CI can `docker load` a cached tarball first). The tag pins only the base image, so key the
  cache on `Containerfile` + `base-image.lock`.
- `ZEEOS_BUILD_CACHE_FROM=<ref>`: passed as `--cache-from`.
- `ZEEOS_KIWI_CACHE=<abs dir>`: mounted at `/var/cache/kiwi` to keep kiwi's package cache.
