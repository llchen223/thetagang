# Building the thetagang Docker image

The image is built end-to-end by [`build-local.sh`](./build-local.sh), which
orchestrates [`extract-installer.sh`](./extract-installer.sh). Run both from the
repository root, which contains the pieces they depend on:

```
.
├── build-local.sh                 # <- run this
├── extract-installer.sh           # called by build-local.sh
├── Dockerfile                     # the image recipe
├── thetagang/                     # application source
├── data/
│   └── jxbrowser-linux64-arm-7.29.jar   # required by the Dockerfile (arm64)
├── dist/                          # produced by `uv build` (the wheel)
└── tws/Jts/                       # produced by extract-installer.sh
```

## Prerequisites

- **Docker** with the daemon running. On macOS this can be the headless Colima
  daemon — see [`COLIMA.md`](./COLIMA.md). Point `DOCKER_HOST` at its socket
  (e.g. `unix://$HOME/.colima/default/docker.sock`) when building so the image
  lands in Colima's store.
- **uv** (https://astral.sh/uv) — builds the Python wheel.
- On **Apple Silicon (arm64)**: Docker must be able to run `linux/amd64` images
  (Rosetta or QEMU). The IBKR TWS installer is x86-only and runs under emulation
  during extraction (handled by `extract-installer.sh` via
  `--platform=linux/amd64`). The *resulting* image is `linux/arm64`.

## One command

From the repository root:

```bash
./build-local.sh
```

This runs three steps and tags the image `llchen223/thetagang:main`:

1. **Build the wheel** — `uv build` → `dist/thetagang-*.whl`.
2. **Extract IBKR TWS** — `extract-installer.sh` downloads the TWS stable
   standalone installer, runs it under `--platform=linux/amd64`, normalizes the
   JVM heap to `-Xmx2048m` for reproducibility, and copies the result to
   `tws/Jts/`. Skipped if `tws/Jts` already exists (override with `FORCE_TWS=1`).
3. **Build the image** — `docker build` against `Dockerfile`, which starts from
   `eclipse-temurin:17`, installs IBC `3.23.0`, and overlays `tws/Jts`, the
   wheel, and the arm jxbrowser jar.

### Useful overrides

`build-local.sh` reads these environment variables:

```bash
IMAGE=thetagang:dev ./build-local.sh     # change the output tag
PLATFORM=linux/arm64 ./build-local.sh    # force target platform
FORCE_TWS=1 ./build-local.sh             # re-extract TWS even if tws/Jts exists
```

> **Architecture note:** this repo only ships the **arm** jxbrowser jar
> (`data/jxbrowser-linux64-arm-7.29.jar`), so a working image is only produced
> for `linux/arm64`. Building `linux/amd64` warns and yields an image whose IB
> Gateway browser will not work.

On success, `build-local.sh` smoke-tests the CLI inside the image:

```
docker run --rm --entrypoint thetagang llchen223/thetagang:main --help
```

## Running

After the image is built, run it as documented in the
[Up and running with Docker](./README.md#up-and-running-with-docker) section.
Runtime configuration and scheduling helpers (launchd plists, `start.sh`,
thetagang configs) live in the companion thetagang-config repository.
