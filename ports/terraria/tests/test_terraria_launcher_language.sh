#!/usr/bin/env bash
# INPUT:  ../love/main.lua、../love/launcher.sh.template、grep/sed/bash
# OUTPUT: 语言选项、共享启动接口与 Shell 语法的回归断言结果
# POS:    泰拉瑞亚声明式界面与启动模板契约的静态回归测试
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ui="$ROOT/love/main.lua"
shfile="$ROOT/love/launcher.sh.template"

grep -Fq 'local launcher = require("launcher")' "$ui"
grep -Fq 'launcher.define {' "$ui"
grep -Fq 'default = "7", env = "TER_LANGUAGE"' "$ui"
grep -Fq '{"1", {en = "English", zh = "英文"}}' "$ui"
grep -Fq '{"12", {en = "Chinese (Traditional)", zh = "繁体中文"}}' "$ui"
grep -Fq 'launcher.output_resolution {env = {"TER_WIDTH", "TER_HEIGHT"}}' "$ui"
grep -Fq 'launcher.render_scale {env = "TER_RENDER_PERCENT"}' "$ui"
grep -Fq '泰拉瑞亚启动器/launch_config.env' "$ui"

grep -Fq 'apply_terraria_language' "$shfile"
grep -Fq 'portkit_launcher json merge' "$shfile"
! sed -n '/^apply_terraria_language()/,/^}/p' "$shfile" | grep -Eq 'sed |awk '
grep -Fq 'local lang="${TER_LANGUAGE:-7}"' "$shfile"
grep -Fq 'local cfg="$CONFDIR/config.json"' "$shfile"
! grep -Fq '/storage/emulated/0/Android/data/com.and.games505.TerrariaPaid/config.json' "$shfile"
grep -Fq '{\"Language\":$lang}' "$shfile"
grep -Fq '#@KIT-BEGIN' "$shfile"
grep -Fq 'source "$KIT/portmaster_bootstrap.sh"' "$shfile"
grep -Fq 'source "$KIT/portmaster_common.sh"' "$shfile"
grep -Fq 'source "$KIT/launcher_unity_common.sh"' "$shfile"
grep -Fq 'run_love_launcher_ui' "$shfile"
grep -Fq 'run_unity_game "$PORT_TOML"' "$shfile"
grep -Fq 'apply_button_remap "$PORT_TOML"' "$shfile"
grep -Fq 'configure_unity_display "$PORT_TOML"' "$shfile"
grep -Fq '"${TER_RENDER_PERCENT:-100}" || exit 1' "$shfile"
! grep -Fq 'bootstrap.pck' "$shfile"
! grep -Fq 'run_godot_launcher' "$shfile"
! grep -Fq 'run_unity_game()' "$shfile"
! grep -Fq 'apply_button_remap()' "$shfile"
bash -n "$shfile"
