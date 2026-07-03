#!/usr/bin/env bash
# Build the STS2 deployable dist/ directory.
#
# This produces the same top-level convention as the other ports:
#   dist/*.sh      -> device Roms/PORTS/
#   dist/non-*.sh  -> device Data/ports/sts2/

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
DIST="$PORT_ROOT/dist"
DATA="$DIST/data_sts2_linuxbsd_arm64"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

rm -rf "$DIST"
mkdir -p "$DIST" "$DATA" "$DIST/gamedata"

blue "=== STS2 dist: build pcks ==="
python3 "$SRC_ROOT/scripts/make-bootstrap-pck.py"
python3 "$SRC_ROOT/scripts/make-overlay-pck.py"

blue "=== STS2 dist: build/copy patcher ==="
if command -v dotnet >/dev/null 2>&1 &&
   [ -f "$SRC_ROOT/refs/0Harmony.dll" ] &&
   [ -f "$SRC_ROOT/refs/sts2.dll" ]; then
  (cd "$SRC_ROOT/STS2LinuxLauncher" && dotnet build -c Release -v:q)
else
  red "missing dotnet or src/refs/{0Harmony.dll,sts2.dll}; cannot build sts2_compat.dll"
  exit 1
fi

blue "=== STS2 dist: collect deploy files ==="
cp "$SRC_ROOT/linux/launcher.sh" "$DIST/Slay the Spire 2.sh"
cp "$SRC_ROOT/linux/data-template/sts2.runtimeconfig.json" "$DATA/"
cp "$SRC_ROOT/linux/gamedata-README.md" "$DIST/gamedata/README.md"
[ -f "$PORT_ROOT/LICENSE" ] && cp "$PORT_ROOT/LICENSE" "$DIST/"
[ -f "$PORT_ROOT/README.md" ] && cp "$PORT_ROOT/README.md" "$DIST/"
[ -f "$PORT_ROOT/README.zh-CN.md" ] && cp "$PORT_ROOT/README.zh-CN.md" "$DIST/"
if [ -f "$PORT_ROOT/screenshot.png" ]; then
  cp "$PORT_ROOT/screenshot.png" "$DIST/screenshot.png"
  cp "$PORT_ROOT/screenshot.png" "$DIST/Slay the Spire 2.png"
  python3 - "$PORT_ROOT/manifest.json" "$PORT_ROOT/screenshot.png" "$DIST" <<'PY'
import json
import os
import shutil
import sys

manifest_path, shot, dist = sys.argv[1:4]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
for name in manifest.get("portmaster", {}).get("image", {}).get("names", []):
    if not isinstance(name, str) or not name:
        continue
    out = name if os.path.splitext(name)[1] else f"{name}.png"
    shutil.copyfile(shot, os.path.join(dist, out))
PY
fi
python3 "$PORT_ROOT/../../_kit/port_json.py" "$PORT_ROOT/manifest.json" "$DIST" "sts2"

cat > "$DIST/input_remap.cfg" <<'EOF'
; default input remap; launcher overwrites based on ABXY layout pick
EOF

# Optional release/runtime files. They are copied when present, but the dist
# command remains usable for dev iteration when external artifacts are absent.
[ -f "$SRC_ROOT/external/godot/godot.linuxbsd.template_release.arm64.mono" ] && {
  cp "$SRC_ROOT/external/godot/godot.linuxbsd.template_release.arm64.mono" "$DIST/godot.mono"
  chmod +x "$DIST/godot.mono"
}
[ -f "$SRC_ROOT/external/godot/GodotSharp.dll" ] && cp "$SRC_ROOT/external/godot/GodotSharp.dll" "$DATA/"
[ -f "$SRC_ROOT/refs/0Harmony.dll" ] && cp "$SRC_ROOT/refs/0Harmony.dll" "$DATA/"

if compgen -G "$SRC_ROOT/external/fmod-gdextension/*.so" >/dev/null; then
  mkdir -p "$DIST/addons/fmod/libs/linux"
  cp "$SRC_ROOT/external/fmod-gdextension"/*.so "$DIST/addons/fmod/libs/linux/"
fi
if [ -f "$SRC_ROOT/external/spine-runtimes/libspine_godot.linux.template_release.arm64.so" ]; then
  mkdir -p "$DIST/addons/spine/linux"
  cp "$SRC_ROOT/external/spine-runtimes/libspine_godot.linux.template_release.arm64.so" "$DIST/addons/spine/linux/"
fi
mkdir -p "$DIST/addons/sentry"
cat > "$DIST/addons/sentry/SentryStub.gd" <<'EOF'
extends Node
# Stub for missing Sentry GDExtension on arm64 Linux.
EOF

bash -n "$DIST/Slay the Spire 2.sh"

green ">>> packaged sts2 -> $DIST"
find "$DIST" -maxdepth 3 -type f | sort | sed "s#^$DIST/##"
