#!/usr/bin/env bash
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech
#
# Build one port into its deployable dist/ directory.
#
# Convention:
#   ports/<port>/src/      editable launcher/runtime inputs
#   ports/<port>/dist/  files that should be copied to the device
#
# Deploy rule:
#   dist/*.sh      -> device Roms/PORTS/
#   dist/non-*.sh  -> device Data/ports/<port>/

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${1:?Usage: _kit/dist_port.sh <port>}"
PORT_DIR="$ROOT/ports/$PORT"
SRC="$PORT_DIR/src"
DIST="$PORT_DIR/dist"
MANIFEST="$PORT_DIR/manifest.json"

[ -d "$PORT_DIR" ] || { echo "no such port: $PORT" >&2; exit 1; }
[ -d "$SRC" ] || { echo "missing source dir: $SRC" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "missing manifest: $MANIFEST" >&2; exit 1; }

if [ -x "$SRC/scripts/dist-port.sh" ]; then
  exec "$SRC/scripts/dist-port.sh"
fi

SCRIPT_NAME="$(python3 - "$MANIFEST" "$PORT" <<'PY'
import json
import sys

manifest_path, port = sys.argv[1:3]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
print(manifest.get("script") or manifest.get("dist", {}).get("script") or f"{port}.sh")
PY
)"

BOOTSTRAP_MANIFEST="$(python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
value = manifest.get("bootstrap_pck")
print(value if isinstance(value, str) else "")
PY
)"

SHOT="$(python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
print(manifest.get("portmaster", {}).get("image", {}).get("screenshot") or "screenshot.png")
PY
)"

rm -rf "$DIST"
mkdir -p "$DIST"

if [ -f "$SRC/launcher.sh" ]; then
  "$ROOT/_kit/assemble.sh" "$SRC/launcher.sh" "$DIST/$SCRIPT_NAME"
fi

if [ -n "$BOOTSTRAP_MANIFEST" ] && [ -f "$PORT_DIR/$BOOTSTRAP_MANIFEST" ]; then
  python3 "$ROOT/_kit/pck_builder.py" "$PORT_DIR/$BOOTSTRAP_MANIFEST"
fi

[ -f "$PORT_DIR/LICENSE" ] && cp "$PORT_DIR/LICENSE" "$DIST/"
[ -f "$PORT_DIR/README.md" ] && cp "$PORT_DIR/README.md" "$DIST/"
if [ -n "$SHOT" ] && [ -f "$PORT_DIR/$SHOT" ]; then
  cp "$PORT_DIR/$SHOT" "$DIST/screenshot.png"
  cp "$PORT_DIR/$SHOT" "$DIST/${SCRIPT_NAME%.sh}.png"
  python3 - "$MANIFEST" "$PORT_DIR/$SHOT" "$DIST" <<'PY'
import json
import os
import shutil
import sys

manifest_path, shot, dist = sys.argv[1:4]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
names = manifest.get("portmaster", {}).get("image", {}).get("names", [])
for name in names:
    if not isinstance(name, str) or not name:
        continue
    out = name if os.path.splitext(name)[1] else f"{name}.png"
    shutil.copyfile(shot, os.path.join(dist, out))
PY
fi
python3 "$ROOT/_kit/port_json.py" "$MANIFEST" "$DIST" "$PORT"

find "$SRC" -maxdepth 1 -type f -name '*.gptk' -exec cp {} "$DIST/" \;
[ -f "$SRC/vs114_language.sh" ] && cp "$SRC/vs114_language.sh" "$DIST/"
[ -d "$SRC/hacksdl" ] && cp -R "$SRC/hacksdl" "$DIST/"

if compgen -G "$DIST/*.sh" >/dev/null; then
  bash -n "$DIST"/*.sh
fi

echo ">>> packaged $PORT -> $DIST"
find "$DIST" -maxdepth 2 -type f | sort | sed "s#^$DIST/##"
