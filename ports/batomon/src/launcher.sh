#!/bin/bash
# PORTMASTER: batomon, Batomon Showdown.sh
# Godot 4 runner for a prepared Batomon Showdown Demo PCK.

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "/opt/system/Tools/PortMaster/" ]; then controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then controlfolder="$XDG_DATA_HOME/PortMaster"
else controlfolder="/roms/ports/PortMaster"
fi
source "$controlfolder/control.txt"
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

GAMEDIR="/$directory/ports/batomon"
CONFDIR="$GAMEDIR/conf"
mkdir -p "$CONFDIR"
cd "$GAMEDIR" || exit 1

ERRLOG="$GAMEDIR/log.txt"
if [ -f "$GAMEDIR/.debug" ]; then
  > "$ERRLOG" && exec > >(tee "$ERRLOG") 2>&1
else
  RUNLOG="/tmp/batomon_run.log"
  > "$RUNLOG" && exec >> "$RUNLOG" 2>&1
  trap 'grep -iE "error|fail|fatal|exception|abort|segfault|crash|panic|script error|user error|no game pck|gdextension" "$RUNLOG" 2>/dev/null | tail -n 200 > "$ERRLOG"' EXIT
fi
echo "[Batomon] CFW=$CFW_NAME ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} GAMEDIR=$GAMEDIR"

export LD_LIBRARY_PATH="$GAMEDIR:$GAMEDIR/addons/godotsteam/linuxarm64:/usr/lib:/usr/lib64:${LD_LIBRARY_PATH}"
export PATH="$GAMEDIR/bin:$PATH"

if [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
  USE_WAYLAND=1
  export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}"
  if [ "$CFW_NAME" = "Loong" ]; then
    GODOT_LAUNCH='exec -a unityloader ./godot.mono'
  else
    GODOT_LAUNCH='./godot.mono'
  fi
else
  USE_WAYLAND=0
  export SDL_VIDEODRIVER=dummy
  export SDL_AUDIODRIVER=alsa
  GODOT_LAUNCH='./godot.mono'
fi

if [ "$USE_WAYLAND" != "1" ]; then
  export XDG_RUNTIME_DIR=/tmp/xdg-batomon
  mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
fi

if command -v pulseaudio >/dev/null 2>&1 && ! pgrep -x pulseaudio >/dev/null 2>&1 && ! pgrep -x pipewire-pulse >/dev/null 2>&1; then
  pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
  sleep 1
fi

GAME_PCK="$GAMEDIR/gamedata/batomon_showdown.pck"
if [ ! -f "$GAME_PCK" ]; then
  echo "[Batomon] no game pck at $GAME_PCK"
  echo "[Batomon] Place the prepared PCK in gamedata/, then restart."
  pm_finish
  exit 1
fi

if [ ! -x "$GAMEDIR/godot.mono" ]; then
  echo "[Batomon] missing executable godot.mono in $GAMEDIR"
  pm_finish
  exit 1
fi

if [ ! -f "$GAMEDIR/addons/godotsteam/linuxarm64/libgodotsteam.linux.template_release.arm64.so" ]; then
  echo "[Batomon] missing GodotSteam arm64 library under addons/godotsteam/linuxarm64/"
fi

cat > "$GAMEDIR/override.cfg" <<'EOF'
[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
EOF

$GPTOKEYB "godot.mono" &
gptokeyb_pid=$!
pm_platform_helper "godot.mono"

VERBOSE_ARG=""
[ -f "$GAMEDIR/.debug" ] && VERBOSE_ARG="--verbose"

SCENE_ARG=()
if [ -n "${BATOMON_SCENE:-}" ]; then
  SCENE_ARG=("$BATOMON_SCENE")
elif [ -f "$GAMEDIR/.scene" ]; then
  read -r scene_from_file < "$GAMEDIR/.scene" || scene_from_file=""
  [ -n "$scene_from_file" ] && SCENE_ARG=("$scene_from_file")
fi

echo "[Batomon] launching $GAME_PCK ${SCENE_ARG[*]:-}"
( XDG_CONFIG_HOME="$CONFDIR" XDG_DATA_HOME="$CONFDIR" \
  $GODOT_LAUNCH $VERBOSE_ARG --display-driver sdl2 --rendering-driver opengl3 \
  --resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} \
  --main-pack "$GAME_PCK" "${SCENE_ARG[@]}" )
code=$?
echo "[Batomon] exit code: $code"

kill $gptokeyb_pid 2>/dev/null
wait $gptokeyb_pid 2>/dev/null
pm_finish
exit "$code"
