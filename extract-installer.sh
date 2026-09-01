#!/bin/sh

set -e
set -x

mkdir -p tws
# --platform=linux/amd64 is required: the IBKR installer is x86-only, so on
# Apple Silicon it must run under emulation (a native arm64 container has no
# x86 loader and the installer dies with a "rosetta error"). On amd64 hosts
# (e.g. GitHub Actions) this is a no-op since amd64 is already native.
#
# The installer's install4j script sizes the default Java heap (-Xmx) from the
# build host's detected physical RAM: an 8 GB Docker VM yields -Xmx768m, while a
# 16 GB GitHub-hosted runner yields -Xmx2048m. We normalise it to 2048m so the
# image is reproducible regardless of how much RAM the build machine has. (This
# is unrelated to emulation -- the emulated amd64 JVM runs -Xmx4096m fine.)
docker run -i --rm --platform=linux/amd64 -v "$(pwd)/tws:/tws" debian sh -c " \
    apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -qy --no-install-recommends unzip curl ca-certificates \
    && echo '5ead02a7d2bd4f3a7b30482c13630e98c04004fbe3c1e2e557589cfa13e2a361  tws-installer.sh' | tee tws-installer.sh.sha256 \
    && curl -qL https://download2.interactivebrokers.com/installers/tws/stable-standalone/tws-stable-standalone-linux-x64.sh -o tws-installer.sh \
    && yes '' | sh tws-installer.sh \
    && rm -f /root/Jts/*/uninstall \
    && sed -i -E 's/^-Xmx[0-9]+m\$/-Xmx2048m/' /root/Jts/*/tws.vmoptions \
    && cp -r /root/Jts /tws"

# && sha256sum -c tws-installer.sh.sha256 \

# Fail loudly if the install silently produced nothing (the installer wrapper
# can exit 0 even when the GUI installer child crashes under emulation).
if ! ls tws/Jts/*/tws.vmoptions >/dev/null 2>&1; then
  echo "ERROR: TWS extraction failed -- tws/Jts/<version>/tws.vmoptions is missing." >&2
  echo "       Check that Docker can run linux/amd64 images (Rosetta/QEMU)." >&2
  exit 1
fi
