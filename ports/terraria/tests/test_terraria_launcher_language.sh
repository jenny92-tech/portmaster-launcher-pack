#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ui="$ROOT/love/main.lua"
shfile="$ROOT/love/launcher.sh.template"

grep -Fq 'local LANG_VALUES = {"1", "7", "12"}' "$ui"
grep -Fq 'resolution = "auto", language = "7"' "$ui"
grep -Fq 'f:write("TER_LANGUAGE=" .. state.language' "$ui"
grep -Fq '泰拉瑞亚启动器/launch_config.env' "$ui"

grep -Fq 'apply_terraria_language' "$shfile"
grep -Fq 'local lang="${TER_LANGUAGE:-7}"' "$shfile"
grep -Fq 'local cfg="$CONFDIR/config.json"' "$shfile"
! grep -Fq '/storage/emulated/0/Android/data/com.and.games505.TerrariaPaid/config.json' "$shfile"
grep -Fq '"Language": %s' "$shfile"
grep -Fq '#@KIT-BEGIN' "$shfile"
grep -Fq 'source "$KIT/portmaster_common.sh"' "$shfile"
grep -Fq 'source "$KIT/launcher_unity_common.sh"' "$shfile"
grep -Fq 'run_love_launcher_ui' "$shfile"
grep -Fq 'run_unity_game "$PORT_TOML"' "$shfile"
grep -Fq 'apply_button_remap "$PORT_TOML"' "$shfile"
! grep -Fq 'bootstrap.pck' "$shfile"
! grep -Fq 'run_godot_launcher' "$shfile"
! grep -Fq 'run_unity_game()' "$shfile"
! grep -Fq 'apply_button_remap()' "$shfile"
bash -n "$shfile"
