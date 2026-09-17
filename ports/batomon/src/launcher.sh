#!/bin/bash
# INPUT:  _kit/launcher_artwork.sh、PortMaster control.txt、godot.mono、玩家 PCK
# OUTPUT: 图形兼容配置、Godot 游戏进程与运行日志
# POS:    Batomon Showdown 的设备环境准备和 Godot 启动入口
# PORTMASTER: batomon, Batomon Showdown.sh
# Godot 4 runner for a prepared Batomon Showdown Demo PCK.

PORT_NAME=batomon
LOG_PREFIX="[Batomon]"

#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/launcher_artwork.sh"
source "$KIT/portmaster_bootstrap.sh"
source "$KIT/launcher_platform.sh"
source "$KIT/portmaster_common.sh"
#@KIT-END
portmaster_sync_launcher_artwork "$(cd "$(dirname "$0")" && pwd)" "$0"

portmaster_init "$(cd "$(dirname "$0")" && pwd)" || exit 1

GAMEDIR="/$directory/ports/batomon"
CONFDIR="$GAMEDIR/conf"
mkdir -p "$CONFDIR"
cd "$GAMEDIR" || exit 1

ERRLOG="$GAMEDIR/log.txt"
if [ -f "$GAMEDIR/.debug" ]; then
  # Plain redirect: process substitution is a bashism that breaks minimal
  # /bin/sh parsers, and no console reads stdout on-device anyway.
  : > "$ERRLOG" && exec >> "$ERRLOG" 2>&1
else
  RUNLOG="/tmp/batomon_run.log"
  > "$RUNLOG" && exec >> "$RUNLOG" 2>&1
  trap 'grep -iE "error|fail|fatal|exception|abort|segfault|crash|panic|script error|user error|no game pck|gdextension" "$RUNLOG" 2>/dev/null | tail -n 200 > "$ERRLOG"' EXIT
fi
echo "[Batomon] CFW=$CFW_NAME ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} GAMEDIR=$GAMEDIR"

export LD_LIBRARY_PATH="$GAMEDIR:/usr/lib:/usr/lib64:${LD_LIBRARY_PATH}"

if ! launcher_platform_display; then
  export SDL_VIDEODRIVER=dummy
  export SDL_AUDIODRIVER=alsa
fi

audio_setup

GAME_PCK="$GAMEDIR/gamedata/batomon_showdown.pck"
if [ ! -f "$GAME_PCK" ]; then
  echo "[Batomon] no game pck at $GAME_PCK"
  echo "[Batomon] Place the original batomon_showdown.pck in gamedata/, then restart."
  pm_finish
  exit 1
fi

if [ ! -x "$GAMEDIR/godot.mono" ]; then
  echo "[Batomon] missing executable godot.mono in $GAMEDIR"
  pm_finish
  exit 1
fi

cat > "$GAMEDIR/override.cfg" <<'EOF'
[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
EOF

$GPTOKEYB "godot.mono" &
gptokeyb_pid=$!
launcher_platform_prepare_game "godot.mono"

VERBOSE_ARG=""
[ -f "$GAMEDIR/.debug" ] && VERBOSE_ARG="--verbose"

# Optional single scene argument. A plain string plus ${VAR:+"$VAR"} keeps
# this parseable by minimal /bin/sh implementations (no bash arrays).
SCENE_ARG=""
if [ -n "${BATOMON_SCENE:-}" ]; then
  SCENE_ARG="$BATOMON_SCENE"
elif [ -f "$GAMEDIR/.scene" ]; then
  read -r scene_from_file < "$GAMEDIR/.scene" || scene_from_file=""
  [ -n "$scene_from_file" ] && SCENE_ARG="$scene_from_file"
fi

echo "[Batomon] launching $GAME_PCK ${SCENE_ARG}"
( XDG_CONFIG_HOME="$CONFDIR" XDG_DATA_HOME="$CONFDIR" \
  launcher_platform_exec ./godot.mono $VERBOSE_ARG --display-driver sdl2 --rendering-driver opengl3 \
  --resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} \
  --main-pack "$GAME_PCK" ${SCENE_ARG:+"$SCENE_ARG"} )
code=$?
echo "[Batomon] exit code: $code"

kill $gptokeyb_pid 2>/dev/null
wait $gptokeyb_pid 2>/dev/null
launcher_platform_finish
exit "$code"
