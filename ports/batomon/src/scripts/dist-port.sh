#!/usr/bin/env bash
# Build the Batomon deployable dist/ directory.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$PORT_ROOT/../.." && pwd)"
DIST="$PORT_ROOT/dist"
GAMEDATA="$DIST/gamedata"
GODOTSTEAM_DIR="$DIST/addons/godotsteam/linuxarm64"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

require_file() {
  [ -f "$1" ] || { red "missing: $1"; exit 1; }
}

rm -rf "$DIST"
mkdir -p "$DIST" "$GAMEDATA" "$GODOTSTEAM_DIR"

blue "=== Batomon dist: collect launcher files ==="
cp "$SRC_ROOT/launcher.sh" "$DIST/Batomon Showdown.sh"
cp "$SRC_ROOT/launcher-offline.sh" "$DIST/Batomon Showdown Offline.sh"
bash -n "$DIST/Batomon Showdown.sh"
bash -n "$DIST/Batomon Showdown Offline.sh"
cp -R "$SRC_ROOT/bin" "$DIST/"
find "$DIST/bin" -type f -exec chmod +x {} +

[ -f "$PORT_ROOT/LICENSE" ] && cp "$PORT_ROOT/LICENSE" "$DIST/"
[ -f "$PORT_ROOT/README.md" ] && cp "$PORT_ROOT/README.md" "$DIST/"
cp "$SRC_ROOT/gamedata-README.md" "$GAMEDATA/README.md"
python3 "$REPO_ROOT/_kit/port_json.py" "$PORT_ROOT/manifest.json" "$DIST" "batomon"

blue "=== Batomon dist: Godot runtime ==="
GODOT_BIN="${GODOT_BIN:-$REPO_ROOT/external/godot/godot.linuxbsd.template_release.arm64.mono}"
require_file "$GODOT_BIN"
cp "$GODOT_BIN" "$DIST/godot.mono"
chmod +x "$DIST/godot.mono"

blue "=== Batomon dist: Steam API stub ==="
STEAM_STUB="${STEAM_STUB:-$REPO_ROOT/../Bogodroid/tools/steam_mock/libsteam_api64.so}"
require_file "$STEAM_STUB"
cp "$STEAM_STUB" "$DIST/libsteam_api64.so"

blue "=== Batomon dist: GodotSteam arm64 GDExtension ==="
require_file "${BATOMON_GODOTSTEAM_ARM64:-}"
cp "$BATOMON_GODOTSTEAM_ARM64" "$GODOTSTEAM_DIR/libgodotsteam.linux.template_release.arm64.so"

if [ -n "${BATOMON_GODOTSTEAM_STEAM_API_ARM64:-}" ]; then
  require_file "$BATOMON_GODOTSTEAM_STEAM_API_ARM64"
  cp "$BATOMON_GODOTSTEAM_STEAM_API_ARM64" "$GODOTSTEAM_DIR/libsteam_api.so"
fi

green ">>> packaged batomon -> $DIST"
find "$DIST" -maxdepth 4 -type f | sort | sed "s#^$DIST/##"
