#!/usr/bin/env bash
# Build the Batomon deployable dist/ directory.
# Uses the batomon-specific Godot from the 4.3-arm64-sdl2-batomon branch,
# which has steam stub + PCK decryption built in.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$PORT_ROOT/../.." && pwd)"
DIST="$PORT_ROOT/dist"
GAMEDATA="$DIST/gamedata"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

require_file() {
  [ -f "$1" ] || { red "missing: $1"; exit 1; }
}

rm -rf "$DIST"
mkdir -p "$DIST" "$GAMEDATA"

blue "=== Batomon dist: launcher ==="
cp "$SRC_ROOT/launcher.sh" "$DIST/Batomon Showdown.sh"
bash -n "$DIST/Batomon Showdown.sh"

[ -f "$PORT_ROOT/LICENSE" ] && cp "$PORT_ROOT/LICENSE" "$DIST/"
[ -f "$PORT_ROOT/README.md" ] && cp "$PORT_ROOT/README.md" "$DIST/"
cp "$SRC_ROOT/gamedata-README.md" "$GAMEDATA/README.md"
python3 "$REPO_ROOT/_kit/port_json.py" "$PORT_ROOT/manifest.json" "$DIST" "batomon"

blue "=== Batomon dist: Godot runtime (4.3-arm64-sdl2-batomon) ==="
GODOT_BIN="${GODOT_BIN:-$REPO_ROOT/external/godot/godot.linuxbsd.template_release.arm64.mono}"
require_file "$GODOT_BIN"
cp "$GODOT_BIN" "$DIST/godot.mono"
chmod +x "$DIST/godot.mono"

green ">>> packaged batomon -> $DIST"
find "$DIST" -maxdepth 4 -type f | sort | sed "s#^$DIST/##"
