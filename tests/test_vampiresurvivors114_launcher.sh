#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="$ROOT/ports/vampiresurvivors114"
LOVE="$PORT/love"

[ -f "$LOVE/launcher.sh.template" ] || { echo "missing love launcher template" >&2; exit 1; }
[ -f "$LOVE/main.lua" ] || { echo "missing love main.lua" >&2; exit 1; }

python3 - "$PORT/manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

expected = "V_吸血鬼幸存者_114.sh"
if manifest.get("script") != expected:
    raise SystemExit(f"manifest script must be {expected!r}")
PY

if [ -f "$PORT/src/vs114_language.sh" ]; then
  echo "vampiresurvivors114 must not ship a language patch script" >&2
  exit 1
fi

if grep -R -nE 'VS_GAME_LANG|vs114_apply_language|I2 Language|SaveDataUnity|game_lang|GAME_LANGS' "$LOVE/launcher.sh.template" "$LOVE/main.lua"; then
  echo "vampiresurvivors114 launcher must not write game language or save data" >&2
  exit 1
fi

if grep -nE 'unityloader\.(gplay|prevgplay)' "$LOVE/launcher.sh.template"; then
  echo "vampiresurvivors114 must use the standard plugin-based unityloader" >&2
  exit 1
fi

grep -Fq 'run_love_launcher_ui' "$LOVE/launcher.sh.template"
grep -Fq 'SHADER_CACHE_DIR="/tmp/bogodroid-cache-com.poncle.vampiresurvivors/UnityShaderCache"' "$LOVE/launcher.sh.template"
grep -Fq 'missing paths.unity_shader_cache_redirect' "$LOVE/launcher.sh.template"
grep -Fq 'run_unity_game "$PORT_TOML" "$GAMEDIR/gamedata/lib:$GAMEDIR/gamedata/lib/arm64-v8a"' "$LOVE/launcher.sh.template"
! grep -Fq 'prepare_unityloader_private_libs' "$LOVE/launcher.sh.template"
! grep -Fq 'LOADER=unityloader' "$LOVE/launcher.sh.template"
grep -Fq 'glVersionOverride        = \"OpenGL ES 3.0 Bogodroid\"' "$LOVE/launcher.sh.template"
grep -Fq 'glMinorVersionOverride   = 0' "$LOVE/launcher.sh.template"
grep -Fq 'shaderGles2Rewrite = false' "$LOVE/launcher.sh.template"
grep -Fq 'local launcher = require("launcher")' "$LOVE/main.lua"
grep -Fq 'launcher.define {' "$LOVE/main.lua"
grep -Fq 'launcher.output_resolution {env = {"VS_WIDTH", "VS_HEIGHT"}}' "$LOVE/main.lua"
grep -Fq 'launcher.render_scale {env = "VS_RENDER_PERCENT"}' "$LOVE/main.lua"
grep -Fq 'apply_render_scale "$PORT_TOML"' "$LOVE/launcher.sh.template"
grep -Fq 'Vampire Survivors Launcher/launch_config.env' "$LOVE/main.lua"
bash -n "$LOVE/launcher.sh.template"
