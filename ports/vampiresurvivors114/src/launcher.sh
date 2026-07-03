#!/bin/bash
# PORTMASTER: vampiresurvivors114, V_吸血鬼幸存者_114.sh
# 1.14.111 对照端口 — 和 1.15 (vampiresurvivors) 完全分开。资源经同一套
# unity_astc 管线压缩(Mode B: --max-size 1280 --block 8x8 --block-small 6x6),
# 73 个大图重压 ASTC。用来和 1.15 交叉对比 libunity 握手死锁。
#
# 自包含:不 source _kit(设备上没有)。先跑 Godot/frt 启动器写分辨率,
# 再进 unityloader。
# loader 用 unityloader.gplay (BD_ENABLE_GPLAY=ON — VS 依赖 Google Play Games)。

PORT_NAME="vampiresurvivors114"; LOG_PREFIX="[VS114]"

# ── PortMaster preamble (controlfolder 发现 + control.txt) ────────────────
XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "/opt/system/Tools/PortMaster/" ]; then controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then controlfolder="$XDG_DATA_HOME/PortMaster"
else controlfolder="/roms/ports/PortMaster"
fi
source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"

GAMEDIR="/$directory/ports/$PORT_NAME"
CONFDIR="$GAMEDIR/conf"
cd "$GAMEDIR"
exec > "$GAMEDIR/log.txt" 2>&1
echo "$LOG_PREFIX CFW=$CFW_NAME ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} GAMEDIR=$GAMEDIR"
mkdir -p "$CONFDIR" "$GAMEDIR/cache/UnityShaderCache"
. "$GAMEDIR/vs114_language.sh"

TRIMUI_RUNNER_PID=""

release_frontend() {
  if [ -n "$TRIMUI_RUNNER_PID" ] && kill -0 "$TRIMUI_RUNNER_PID" 2>/dev/null; then
    echo "$LOG_PREFIX resume runtrimui.sh pid=$TRIMUI_RUNNER_PID"
    kill -CONT "$TRIMUI_RUNNER_PID" 2>/dev/null
  fi
}

acquire_display() {
  if pidof MainUI >/dev/null 2>&1; then
    set -- $(pidof runtrimui.sh 2>/dev/null)
    TRIMUI_RUNNER_PID="$1"
    if [ -n "$TRIMUI_RUNNER_PID" ]; then
      echo "$LOG_PREFIX pause runtrimui.sh pid=$TRIMUI_RUNNER_PID"
      kill -STOP "$TRIMUI_RUNNER_PID" 2>/dev/null
    fi

    echo "$LOG_PREFIX stop MainUI for DRM master"
    killall -KILL MainUI 2>/dev/null
    sleep 1
  fi
}

audio_setup() {
  if [ "$CFW_NAME" = "Loong" ]; then
    echo "$LOG_PREFIX Loong: system audio + XDG_RUNTIME_DIR left untouched"
    return
  fi

  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-${PORT_NAME}}"
  mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null && chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
  if pgrep -x pulseaudio >/dev/null 2>&1 || pgrep -x pipewire-pulse >/dev/null 2>&1; then
    echo "$LOG_PREFIX pulse/pipewire daemon already up"
  elif command -v pulseaudio >/dev/null 2>&1; then
    pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1
    sleep 1
  else
    echo "$LOG_PREFIX no pulseaudio on this CFW - direct ALSA"
  fi

  if command -v pactl >/dev/null 2>&1 && ! pactl list short sinks 2>/dev/null | grep -qv auto_null; then
    pactl load-module module-alsa-sink device=default tsched=0 >/dev/null 2>&1
    sink=$(pactl list short sinks 2>/dev/null | grep -v auto_null | head -1 | awk '{print $2}')
    [ -n "$sink" ] && pactl set-default-sink "$sink" >/dev/null 2>&1
    echo "$LOG_PREFIX pulse -> ALSA default ($sink)"
  fi
}

trap release_frontend EXIT INT TERM
acquire_display
get_controls

# ── Stage 1: Godot/frt launcher UI ──────────────────────────────────────
find_godot_binary() {
  GODOT_BIN=""; GODOT_KIND=""; GODOT_RT_DIR=""; GODOT_FRT_NAME=""

  local squash
  squash=$(ls "$controlfolder/libs"/frt_3.*.squashfs 2>/dev/null | sort -V | tail -1)
  if [ -n "$squash" ]; then
    GODOT_FRT_NAME="$(basename "$squash" .squashfs)"
    GODOT_RT_DIR="$HOME/godot"
    $ESUDO mkdir -p "$GODOT_RT_DIR"
    $ESUDO umount "$GODOT_RT_DIR" 2>/dev/null
    $ESUDO mount "$squash" "$GODOT_RT_DIR"
    GODOT_BIN="$GODOT_RT_DIR/$GODOT_FRT_NAME"; GODOT_KIND="frt3"
    echo "$LOG_PREFIX $GODOT_FRT_NAME: $GODOT_BIN"
    return 0
  fi

  echo "$LOG_PREFIX no frt_3 launcher runtime — UI will be skipped"
  return 1
}

run_launcher_ui() {
  local pck="$GAMEDIR/bootstrap.pck"
  if ! find_godot_binary || [ ! -f "$pck" ]; then
    echo "$LOG_PREFIX no launcher UI / bootstrap.pck — using current vs.toml"
    return 0
  fi

  echo "$LOG_PREFIX stage 1: launcher UI ($GODOT_BIN)"
  export FRT_NO_EXIT_SHORTCUTS=FRT_NO_EXIT_SHORTCUTS
  export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
  $GPTOKEYB "$GODOT_FRT_NAME" -c "$GAMEDIR/${PORT_NAME}.gptk" &
  local gptokeyb_pid=$!
  pm_platform_helper "$GODOT_FRT_NAME"
  LD_PRELOAD="$GAMEDIR/hacksdl/hacksdl.aarch64.so" HACKSDL_DEVICE_DISABLE_0=2 \
  XDG_CONFIG_HOME="$CONFDIR" XDG_DATA_HOME="$CONFDIR" \
  GODOT_SILENCE_ROOT_WARNING=1 \
    "$GODOT_BIN" --resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} --main-pack "$pck"
  local launcher_exit=$?
  kill $gptokeyb_pid 2>/dev/null; wait $gptokeyb_pid 2>/dev/null
  [ -n "$GODOT_RT_DIR" ] && $ESUDO umount "$GODOT_RT_DIR" 2>/dev/null

  echo "$LOG_PREFIX launcher exited: $launcher_exit"
  if [ "$launcher_exit" = "0" ]; then
    echo "$LOG_PREFIX user quit — back to menu."
    pm_finish; exit 0
  elif [ "$launcher_exit" != "42" ]; then
    echo "$LOG_PREFIX launcher UI failed ($launcher_exit) — starting game anyway."
  fi
}

apply_button_remap() {
  local toml="$1" a="$2" b="$3" x="$4" y="$5"
  awk -v a="$a" -v b="$b" -v x="$x" -v y="$y" '
    /^\[input\.remap\]/ { print; inblk=1; da=db=dx=dy=0; next }
    inblk && /^\[/ {
      if(!da) printf "a       = \"%s\"\n", a
      if(!db) printf "b       = \"%s\"\n", b
      if(!dx) printf "x       = \"%s\"\n", x
      if(!dy) printf "y       = \"%s\"\n", y
      inblk=0
    }
    inblk && /^a *=/ { printf "a       = \"%s\"\n", a; da=1; next }
    inblk && /^b *=/ { printf "b       = \"%s\"\n", b; db=1; next }
    inblk && /^x *=/ { printf "x       = \"%s\"\n", x; dx=1; next }
    inblk && /^y *=/ { printf "y       = \"%s\"\n", y; dy=1; next }
    { print }
    END { if(inblk){ if(!da)printf"a       = \"%s\"\n",a; if(!db)printf"b       = \"%s\"\n",b; if(!dx)printf"x       = \"%s\"\n",x; if(!dy)printf"y       = \"%s\"\n",y } }
  ' "$toml" > "$toml.tmp" && mv "$toml.tmp" "$toml"
}

run_launcher_ui

VS_ENV="$CONFDIR/godot/app_userdata/Vampire Survivors Launcher/launch_config.env"
if [ -f "$VS_ENV" ]; then
  source "$VS_ENV"
  VS_WIDTH=auto
  VS_HEIGHT=auto
  VS_GAME_LANG=${VS_GAME_LANG:-zh-CN}
  echo "$LOG_PREFIX env: ${VS_WIDTH}x${VS_HEIGHT} game_lang=$VS_GAME_LANG swap_ab=$VS_SWAP_AB swap_xy=$VS_SWAP_XY"

  if [ "$VS_WIDTH" = "auto" ]; then
    VS_WIDTH="$DISPLAY_WIDTH"; VS_HEIGHT="$DISPLAY_HEIGHT"
    echo "$LOG_PREFIX resolution auto -> ${VS_WIDTH}x${VS_HEIGHT}"
  fi
  case "$VS_WIDTH$VS_HEIGHT" in
    *[!0-9]*|"") echo "$LOG_PREFIX bad resolution in env, keeping current vs.toml" ;;
    *)
      sed -i "s/^displayWidth=.*/displayWidth=${VS_WIDTH}/" "$GAMEDIR/vs.toml"
      sed -i "s/^displayHeight=.*/displayHeight=${VS_HEIGHT}/" "$GAMEDIR/vs.toml"
      ;;
  esac
  if [ "$VS_SWAP_AB" = "on" ]; then A_V=BUTTON_B; B_V=BUTTON_A; else A_V=BUTTON_A; B_V=BUTTON_B; fi
  if [ "$VS_SWAP_XY" = "on" ]; then X_V=BUTTON_Y; Y_V=BUTTON_X; else X_V=BUTTON_X; Y_V=BUTTON_Y; fi
  vs114_apply_language "$GAMEDIR/vs.toml" "$CONFDIR" "$VS_GAME_LANG"
  apply_button_remap "$GAMEDIR/vs.toml" "$A_V" "$B_V" "$X_V" "$Y_V"
else
  echo "$LOG_PREFIX no launch_config.env — using current vs.toml"
fi

# Unity Loader now resolves Android base assets and Play Asset Delivery pack
# assets internally. Keep the launcher focused on UI/config; do not bind
# gamedata/assets or Addressables aa here.

# ── Safe GL defaults ─────────────────────────────────────────────────────
sed -i "s/^glVersionOverride.*/glVersionOverride        = \"OpenGL ES 3.2 Bogodroid\"/" "$GAMEDIR/vs.toml"
sed -i "s/^glMajorVersionOverride.*/glMajorVersionOverride   = 3/" "$GAMEDIR/vs.toml"
sed -i "s/^glMinorVersionOverride.*/glMinorVersionOverride   = 2/" "$GAMEDIR/vs.toml"
sed -i "s/^textureMaxDim *=.*/textureMaxDim = 0/" "$GAMEDIR/vs.toml"

# ── 库路径 + 1GB 掌机 glibc 内存收敛 ─────────────────────────────────────
export XDG_DATA_HOME="$CONFDIR" XDG_CONFIG_HOME="$CONFDIR"
export LD_LIBRARY_PATH="$GAMEDIR/gamedata/lib:$GAMEDIR/gamedata/lib/arm64-v8a:$LD_LIBRARY_PATH"
export MALLOC_ARENA_MAX=2
export MALLOC_TRIM_THRESHOLD_=131072
export MALLOC_MMAP_THRESHOLD_=131072

# Unity 6/PAD compatibility is handled in the loader.

# ── 选 loader: 优先 .gplay (Google Play 开),回退到 .prevgplay / unityloader ──
LOADER=unityloader
for c in unityloader.gplay unityloader.prevgplay; do
  [ -x "$GAMEDIR/$c" ] && { LOADER="$c"; break; }
done
chmod a+x "$GAMEDIR/$LOADER"
echo "$LOG_PREFIX loader=$LOADER"
audio_setup
pm_platform_helper "$GAMEDIR/$LOADER"

# ── run ──────────────────────────────────────────────────────────────────
"$GAMEDIR/$LOADER" vs.toml
STATUS=$?
echo "$LOG_PREFIX exited $STATUS"
exit "$STATUS"
