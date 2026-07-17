#!/usr/bin/env bash
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech
#
# Fetch the frt runtime this port bundles. Kept out of git (12 MB binary), so
# run this once after cloning, before _kit/dist_port.sh appmanager.
#
# The same squashfs serves two jobs: it runs our own UI, and it IS the payload
# the "repair runtime" feature copies into PortMaster's libs/.

set -euo pipefail

RT="frt_3.6"
DEST="$(cd "$(dirname "$0")/.." && pwd)/runtime"
URL="https://github.com/PortsMaster/PortMaster-Runtime/releases/download/runtimes/${RT}.squashfs"

mkdir -p "$DEST"
if [ -f "$DEST/${RT}.squashfs" ]; then
  echo ">>> already present: $DEST/${RT}.squashfs"
  exit 0
fi

echo ">>> fetching $URL"
curl -fL --progress-bar -o "$DEST/${RT}.squashfs.part" "$URL"
mv "$DEST/${RT}.squashfs.part" "$DEST/${RT}.squashfs"
echo ">>> $(ls -la "$DEST/${RT}.squashfs")"
