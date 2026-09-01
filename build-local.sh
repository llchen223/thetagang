#!/usr/bin/env bash
#
# build-local.sh -- fully build the thetagang Docker image locally.
#
# Performs every step the CI "build-and-push" job does, end to end:
#   1. build the Python wheel              (uv build        -> dist/)
#   2. extract the IBKR TWS install         (extract-installer.sh -> tws/Jts)
#   3. build the Docker image               (docker build    -> $IMAGE)
#
# Works on Apple Silicon (arm64) and amd64 Linux/macOS hosts. The IBKR
# installer is x86-only and runs under emulation on arm64 (handled by
# extract-installer.sh via --platform=linux/amd64).
#
# Usage:
#   ./build-local.sh                 # build for the host's native architecture
#   IMAGE=thetagang:dev ./build-local.sh
#   PLATFORM=linux/arm64 ./build-local.sh
#   FORCE_TWS=1 ./build-local.sh     # re-extract TWS even if tws/Jts exists
#
set -euo pipefail

cd "$(dirname "$0")"

# ---- configuration -----------------------------------------------------------
IMAGE="${IMAGE:-llchen223/thetagang:main}"

# The repo only ships the arm jxbrowser jar (data/jxbrowser-linux64-arm-*.jar),
# so the produced image is only valid for linux/arm64. Default to the host arch
# but refuse to silently build a broken amd64 image.
host_arch="$(uname -m)"
case "$host_arch" in
  arm64 | aarch64) default_platform="linux/arm64" ;;
  x86_64 | amd64)  default_platform="linux/amd64" ;;
  *)               default_platform="linux/arm64" ;;
esac
PLATFORM="${PLATFORM:-$default_platform}"

# ---- prerequisite checks -----------------------------------------------------
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found on PATH." >&2; exit 1; }
command -v uv     >/dev/null 2>&1 || { echo "ERROR: uv not found on PATH (https://astral.sh/uv)." >&2; exit 1; }
docker info >/dev/null 2>&1        || { echo "ERROR: Docker daemon is not running." >&2; exit 1; }

if [ "$PLATFORM" = "linux/amd64" ] && ! ls data/jxbrowser-linux64-amd64-*.jar >/dev/null 2>&1; then
  echo "WARNING: building for linux/amd64 but only the arm jxbrowser jar is present;" >&2
  echo "         the resulting image's IB Gateway browser will likely not work." >&2
fi

echo ">> Target image : $IMAGE"
echo ">> Platform     : $PLATFORM  (host: $host_arch)"

# ---- 1. build the wheel ------------------------------------------------------
echo ">> [1/3] Building Python wheel (uv build)"
# Clean stale artifacts first: the Dockerfile globs dist/thetagang-*.whl, and
# wheels from a previous version left in dist/ make uv reject the install
# ("conflicting URLs for package"). A clean checkout (as in CI) never has them.
rm -rf dist
uv build

# ---- 2. extract TWS ----------------------------------------------------------
if [ -n "${FORCE_TWS:-}" ] || ! ls tws/Jts/*/tws.vmoptions >/dev/null 2>&1; then
  echo ">> [2/3] Extracting IBKR TWS installer (extract-installer.sh)"
  ./extract-installer.sh
else
  echo ">> [2/3] TWS already extracted (tws/Jts present); set FORCE_TWS=1 to redo"
fi

# ---- 3. build the image ------------------------------------------------------
echo ">> [3/3] Building Docker image"
DOCKER_BUILDKIT=1 docker build --platform="$PLATFORM" -t "$IMAGE" .

echo ">> Done. Verifying CLI inside the image:"
docker run --rm --entrypoint thetagang "$IMAGE" --help | head -3
echo ">> Built $IMAGE"
