#!/usr/bin/env bash
# Build dist/ and push it to a device over SSH.
#
# Usage:
#   ports/sts2/src/scripts/deploy-to-device.sh
#   DEVICE=root@10.10.1.91 ports/sts2/src/scripts/deploy-to-device.sh

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
DIST="$PORT_ROOT/dist"

DEVICE="${DEVICE:-root@10.10.1.193}"
PORT_PATH="${PORT_PATH:-/mnt/sdcard/mmcblk1p1/Data/ports/sts2}"
PORTMASTER_PATH="${PORTMASTER_PATH:-/mnt/sdcard/mmcblk1p1/Roms/PORTS}"
# Launcher script name is single-sourced from the manifest (same rule as
# _kit/dist_port.sh); LAUNCHER_NAME only overrides the on-device name.
SCRIPT_NAME="$(python3 - "$PORT_ROOT/manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
print(manifest.get("script") or "sts2.sh")
PY
)"
LAUNCHER_NAME="${LAUNCHER_NAME:-$SCRIPT_NAME}"

blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }

"$SRC_ROOT/scripts/dist-port.sh"

[ -f "$DIST/$SCRIPT_NAME" ] || { echo "missing dist launcher"; exit 1; }
[ -f "$DIST/love_ui/main.lua" ] || { echo "missing dist/love_ui/main.lua"; exit 1; }
[ -f "$DIST/love_ui/kit.lua" ] || { echo "missing dist/love_ui/kit.lua"; exit 1; }
[ -f "$DIST/port_compat.pck" ] || { echo "missing dist/port_compat.pck"; exit 1; }
[ -f "$DIST/data_sts2_linuxbsd_arm64/sts2_compat.dll" ] || { echo "missing dist sts2_compat.dll"; exit 1; }

blue "=== ssh $DEVICE ==="
ssh -o ConnectTimeout=5 "$DEVICE" 'echo alive' >/dev/null

blue "=== push launcher script ==="
scp "$DIST/$SCRIPT_NAME" "$DEVICE:$PORTMASTER_PATH/$LAUNCHER_NAME"

blue "=== push port dist ==="
rsync -a --delete --exclude='*.sh' "$DIST/" "$DEVICE:$PORT_PATH/"

green "=== done ==="
echo "next: launch on device and inspect $PORT_PATH/log.txt"
