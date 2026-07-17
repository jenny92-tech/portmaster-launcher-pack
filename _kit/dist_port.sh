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
# love 启动器的 port 不再需要 src/(godot 启动器已删); 只要有 love/ 或 src/ 之一即可。
[ -d "$SRC" ] || [ -d "$PORT_DIR/love" ] || { echo "missing source dir: $SRC (and no love/)" >&2; exit 1; }
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

# love 启动器优先: 存在 love/launcher.sh.template 时它就是 stage-1(替代 frt/godot)。
# love_ui = 共享 _kit/love/kit.lua + 本 port 的 main/conf/gptk(font.ttf 运行时供给);
# 这一段是所有 love port 的通用组装步骤。
LOVE_DIR="$PORT_DIR/love"
USE_LOVE=""
if [ -f "$LOVE_DIR/launcher.sh.template" ]; then
  USE_LOVE=1
  "$ROOT/_kit/assemble.sh" "$LOVE_DIR/launcher.sh.template" "$DIST/$SCRIPT_NAME"
elif [ -f "$LOVE_DIR/main.lua" ] && [ -f "$SRC/launcher.sh" ]; then
  # Complex ports such as APP Manager keep their safety-critical shell in src/
  # while replacing only the UI/runtime layer with LÖVE.
  USE_LOVE=1
  "$ROOT/_kit/assemble.sh" "$SRC/launcher.sh" "$DIST/$SCRIPT_NAME"
fi

if [ -n "$USE_LOVE" ]; then
  mkdir -p "$DIST/love_ui"
  # Shared LÖVE runtime layer. Ports only carry main.lua and optional overrides.
  cp "$ROOT/_kit/love/"*.lua "$DIST/love_ui/"
  cp "$ROOT/_kit/love/ui.gptk" "$DIST/love_ui/"
  # 通用启动器背景(品牌 Logo 在图内): 所有 love port 共享这一张。
  [ -f "$ROOT/_kit/love/launcher_bg.png" ] && cp "$ROOT/_kit/love/launcher_bg.png" "$DIST/love_ui/"
  # Port-specific Lua modules and optional asset overrides.
  cp "$LOVE_DIR/"*.lua "$DIST/love_ui/"
  for f in conf.lua ui.gptk launcher_bg.png; do
    [ -f "$LOVE_DIR/$f" ] && cp "$LOVE_DIR/$f" "$DIST/love_ui/"
  done
elif [ -f "$SRC/launcher.sh" ]; then
  "$ROOT/_kit/assemble.sh" "$SRC/launcher.sh" "$DIST/$SCRIPT_NAME"
fi

# bootstrap.pck 只给 frt/godot 启动器用; love 启动器不需要, 跳过。
if [ -z "$USE_LOVE" ] && [ -n "$BOOTSTRAP_MANIFEST" ] && [ -f "$PORT_DIR/$BOOTSTRAP_MANIFEST" ]; then
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

# 以下都是 src/ 里的可选运行时/输入文件; love-only 的 port 没有 src/, 跳过即可。
if [ -d "$SRC" ]; then
  find "$SRC" -maxdepth 1 -type f -name '*.gptk' -exec cp {} "$DIST/" \;
  # A port may bundle its own runtime instead of relying on PortMaster libs/.
  [ -z "$USE_LOVE" ] && [ -d "$SRC/runtime" ] && cp -R "$SRC/runtime" "$DIST/"
  [ -f "$SRC/vs114_language.sh" ] && cp "$SRC/vs114_language.sh" "$DIST/"
  [ -z "$USE_LOVE" ] && [ -d "$SRC/hacksdl" ] && cp -R "$SRC/hacksdl" "$DIST/"
fi

if compgen -G "$DIST/*.sh" >/dev/null; then
  bash -n "$DIST"/*.sh
fi

echo ">>> packaged $PORT -> $DIST"
find "$DIST" -maxdepth 2 -type f | sort | sed "s#^$DIST/##"
