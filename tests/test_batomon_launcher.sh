#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="$ROOT/ports/batomon"
MANIFEST="$PORT/manifest.json"
SCRIPT="$PORT/src/launcher.sh"
DIST_SCRIPT="$PORT/src/scripts/dist-port.sh"

[ -f "$MANIFEST" ] || { echo "missing manifest: $MANIFEST" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "missing launcher: $SCRIPT" >&2; exit 1; }
[ -x "$DIST_SCRIPT" ] || { echo "missing executable dist script: $DIST_SCRIPT" >&2; exit 1; }

python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

assert manifest["port_dir"] == "batomon"
assert manifest["script"] == "Batomon Showdown.sh"
assert manifest["launcher_sh"] == "src/launcher.sh"
assert manifest["engine"].startswith("Godot 4")
PY

grep -Fq 'GAME_PCK="$GAMEDIR/gamedata/batomon_showdown.pck"' "$SCRIPT"
grep -Fq './godot.mono' "$SCRIPT"
grep -Fq 'BATOMON_SCENE' "$SCRIPT"
grep -Fq 'source "$controlfolder/control.txt"' "$SCRIPT"

grep -Fq 'cp "$SRC_ROOT/launcher.sh" "$DIST/Batomon Showdown.sh"' "$DIST_SCRIPT"
grep -Fq 'external/godot/godot.linuxbsd.template_release.arm64.mono' "$DIST_SCRIPT"
grep -Fq 'port_json.py' "$DIST_SCRIPT"

# The current port is a single-launcher, user-supplied-PCK build. Tests must not
# resurrect old offline/helper artifacts that are absent from the manifest.
! grep -Fq 'launcher-offline.sh' "$DIST_SCRIPT"
! grep -Fq 'prepare-batomon-pck.py' "$DIST_SCRIPT"

bash -n "$SCRIPT"
bash -n "$DIST_SCRIPT"
echo "batomon launcher tests: PASS"
