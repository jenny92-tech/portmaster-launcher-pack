#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="$ROOT/ports/vampiresurvivors114"
SRC="$PORT/src"

[ -f "$SRC/launcher.sh" ] || { echo "missing launcher.sh" >&2; exit 1; }
[ -f "$SRC/launcher_ui.gd" ] || { echo "missing launcher_ui.gd" >&2; exit 1; }

python3 - "$PORT/manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

expected = "V_吸血鬼幸存者_114.sh"
if manifest.get("script") != expected:
    raise SystemExit(f"manifest script must be {expected!r}")
PY

if [ -f "$SRC/vs114_language.sh" ]; then
  echo "vampiresurvivors114 must not ship a language patch script" >&2
  exit 1
fi

if grep -R -nE 'VS_GAME_LANG|vs114_apply_language|I2 Language|SaveDataUnity|game_lang|GAME_LANGS' "$SRC/launcher.sh" "$SRC/launcher_ui.gd"; then
  echo "vampiresurvivors114 launcher must not write game language or save data" >&2
  exit 1
fi
