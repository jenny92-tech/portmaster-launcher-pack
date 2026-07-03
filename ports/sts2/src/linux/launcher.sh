#!/bin/bash
# PORTMASTER: sts2_lite, Slay the Spire 2.sh
# Stage 1: GDScript launcher UI (bootstrap.pck) — quality / language / layout
# Stage 2: game (gamedata/pcks/SlayTheSpire2.pck) — swap + gptokeyb

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "/opt/system/Tools/PortMaster/" ]; then controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then controlfolder="$XDG_DATA_HOME/PortMaster"
else controlfolder="/roms/ports/PortMaster"
fi
source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

GAMEDIR="/$directory/ports/sts2"
CONFDIR="$GAMEDIR/conf"
mkdir -p "$CONFDIR"
cd "$GAMEDIR"

# Logging: .debug marker on SD → full verbose to SD log.txt;
# otherwise quiet: everything goes to RAM tmpfs, only errors/warnings
# are extracted to a small SD log.txt on exit. SLL_DEBUG forwarded to patcher.
ERRLOG="$GAMEDIR/log.txt"
if [ -f "$GAMEDIR/.debug" ]; then
  export SLL_DEBUG=1
  > "$ERRLOG" && exec > >(tee "$ERRLOG") 2>&1
else
  export SLL_DEBUG=0
  RUNLOG="/tmp/sts2_run.log"
  > "$RUNLOG" && exec >> "$RUNLOG" 2>&1
  trap 'grep -iE "error|fail|fatal|exception|abort|segfault|crash|panic|script error|user error|no game pck" "$RUNLOG" 2>/dev/null | tail -n 200 > "$ERRLOG"' EXIT
fi
echo "[STS2] CFW=$CFW_NAME ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} GAMEDIR=$GAMEDIR debug=$SLL_DEBUG"

# Device-specific lib paths are sourced from PortMaster; we prepend standard
# /usr/lib for libmali/libEGL which PortMaster may not include.
export LD_LIBRARY_PATH="/usr/lib:/usr/lib64:${LD_LIBRARY_PATH}"

# Display is universal: ONE binary, the SDL2 video driver picks the platform.
# RULE: detect the display by what the CFW actually provides, not by CFW name.
#   Compositor present (a wayland-N socket exists → ROCKNIX/sway, Loong/weston):
#     the CFW session already exported SDL_VIDEODRIVER=wayland + WAYLAND_DISPLAY.
#     Render as a wayland client; compositor composites + applies output rotation
#     → no KMS scanout fight, no manual rotation. Do NOT override the CFW's env.
#   No compositor (TrimUI bare KMS): nothing is exported; SDL would auto-pick its
#     own kmsdrm, NOT our custom backend. Force SDL_VIDEODRIVER=dummy so DSDL2's
#     custom KMS+GBM+EGL path drives the panel directly (unchanged).
# --display-driver sdl2 + --rendering-driver opengl3 are identical on both.
if [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
  USE_WAYLAND=1
  export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}"
  if [ "$CFW_NAME" = "Loong" ]; then
    # loong_pangu only raises whitelisted wayland app_ids; "godot.mono" is not one,
    # so pangu keeps its menu over our surface (missing chunk + ghosting). SDL takes
    # the app_id from argv[0] (SDL_APP_ID env ignored on this build), so launch as
    # argv[0]="unityloader" via exec -a. Binary/comm stay godot.mono (gptokeyb OK).
    GODOT_LAUNCH='exec -a unityloader ./godot.mono'
  else
    # ROCKNIX/sway and other compositors map new toplevels normally — no app_id hack.
    GODOT_LAUNCH='./godot.mono'
  fi
else
  USE_WAYLAND=0
  export SDL_VIDEODRIVER=dummy
  export SDL_AUDIODRIVER=alsa   # TrimUI: no CFW audio env, keep prior behavior
  GODOT_LAUNCH='./godot.mono'
fi

# Panfrost shader 编译奇慢的两处对策(仅 Panfrost;libmali 会 JOB_READ_FAULT 但不支持 sts2):
# 粒子 shader 不编译(否则战斗卡死) + mesh canvas 强制默认 shader。
export GODOT_DISABLE_PARTICLES=1
export GODOT_DEFSHADER_TYPES="mesh,multimesh"

# ═══════════════ STAGE 1: launcher UI ═══════════════════════════════════
# No gptokeyb during launcher (it EVIOCGRABs event4, blocking godot evdev).
# Hide the game's override.cfg (1280×720 viewport) — launcher runs full-res.
[ -f "$GAMEDIR/override.cfg" ] && mv "$GAMEDIR/override.cfg" "$GAMEDIR/override.cfg.gamehide"
echo "[STS2] stage 1: launcher (bootstrap.pck)"
( XDG_CONFIG_HOME="$CONFDIR" XDG_DATA_HOME="$CONFDIR" \
  $GODOT_LAUNCH --display-driver sdl2 --rendering-driver opengl3 \
  --resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} \
  --main-pack "$GAMEDIR/bootstrap.pck" )
launcher_exit=$?
[ -f "$GAMEDIR/override.cfg.gamehide" ] && mv "$GAMEDIR/override.cfg.gamehide" "$GAMEDIR/override.cfg"
echo "[STS2] launcher exited: $launcher_exit"

if [ "$launcher_exit" != "42" ]; then
  echo "[STS2] not StartGame — quitting."
  pm_finish
  exit 0
fi

# ═══════════════ STAGE 2: game ═══════════════════════════════════════════
# launch_config.env written by stage 1 UI → source into godot.mono's env.
export SLL_LANGUAGE SLL_LAYOUT SLL_QUALITY 2>/dev/null || true
SLL_ENV="$CONFDIR/godot/app_userdata/STS2 Linux Launcher/launch_config.env"
[ -f "$SLL_ENV" ] && source "$SLL_ENV"
case "$SLL_LANGUAGE" in en_US|zh_CN) ;; *) SLL_LANGUAGE=en_US ;; esac

case "$SLL_LANGUAGE" in zh_CN) GAME_LANG=zhs ;; *) GAME_LANG=eng ;; esac
# 宽高比按设备屏幕自动设(免去玩家手动进设置):4:3 面板(MiniLoong 960x720)→
# four_by_three;其余(吹米 1280x720 等 16:9)→ sixteen_by_nine。WxH 整除判断。
if [ $((DISPLAY_WIDTH * 3)) -eq $((DISPLAY_HEIGHT * 4)) ]; then
  GAME_ASPECT=four_by_three
else
  GAME_ASPECT=sixteen_by_nine
fi
for SF in "$CONFDIR"/SlayTheSpire2/*/*/settings.save; do
  [ -f "$SF" ] || continue
  sed -i 's/"language": "[a-z]*"/"language": "'$GAME_LANG'"/' "$SF"
  sed -i 's/"aspect_ratio": "[a-z_]*"/"aspect_ratio": "'$GAME_ASPECT'"/' "$SF"
done

# Audio: use existing daemon, start pulseaudio if available, or fall back to ALSA.
# XDG_RUNTIME_DIR: override ONLY when we are NOT a wayland client. Any compositor
# (ROCKNIX/sway, Loong/weston) needs the *system* XDG_RUNTIME_DIR to find the
# wayland-N socket — clobbering it would kill the display. Bare-KMS (TrimUI) gets
# a writable runtime dir for pulse's socket.
if [ "$USE_WAYLAND" != "1" ]; then
  export XDG_RUNTIME_DIR=/tmp/xdg-sts2
  mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
fi
GODOT_AUDIO_ARG=""
if pgrep -x pulseaudio >/dev/null 2>&1 || pgrep -x pipewire-pulse >/dev/null 2>&1; then
  echo "[STS2] pulse/pipewire daemon already running"
elif command -v pulseaudio >/dev/null 2>&1; then
  pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1
  sleep 1
  if ! pactl list short sinks 2>/dev/null | grep -qv auto_null; then
    pactl load-module module-alsa-sink device=default tsched=0 >/dev/null 2>&1
    SINK=$(pactl list short sinks 2>/dev/null | grep -v auto_null | head -1 | awk '{print $2}')
    [ -n "$SINK" ] && pactl set-default-sink "$SINK" >/dev/null 2>&1
    echo "[STS2] pulse → ALSA default ($SINK)"
  fi
else
  echo "[STS2] no pulse, godot falls back to ALSA (FMOD music unavailable)"
  GODOT_AUDIO_ARG="--audio-driver ALSA"
fi

# gamedata overlay: cp player's MegaCrit files to runtime data_/.
# -fu: skip copy when mtime matches → zero SD writes after second launch.
GAMEDATA="$GAMEDIR/gamedata"
if [ -d "$GAMEDATA/data_sts2_linuxbsd_arm64" ]; then
  cp -fu "$GAMEDATA/data_sts2_linuxbsd_arm64/"*.dll  "$GAMEDIR/data_sts2_linuxbsd_arm64/" 2>/dev/null
  cp -fu "$GAMEDATA/data_sts2_linuxbsd_arm64/"*.json "$GAMEDIR/data_sts2_linuxbsd_arm64/" 2>/dev/null
fi

GAME_PCK="$GAMEDATA/pcks/SlayTheSpire2.pck"
if [ ! -f "$GAME_PCK" ]; then
  echo "[STS2] no game pck at $GAME_PCK"
  echo "[STS2] Place game files in $GAMEDATA/ (see README), then restart."
  pm_finish
  exit 1
fi

# override.cfg: Mali-required settings + patcher entry redirect.
# Panel size/rotation via GODOT_SDL2 env vars (DRM defaults).
cat > "$GAMEDIR/override.cfg" << 'EOF'
[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"

[dotnet]
project/assembly_name="sts2_compat"
EOF

$GPTOKEYB "godot.mono" &
pm_platform_helper "godot.mono"

VERBOSE_ARG=""
[ "$SLL_DEBUG" = "1" ] && VERBOSE_ARG="--verbose"
echo "[STS2] stage 2: lang=$SLL_LANGUAGE quality=$SLL_QUALITY debug=$SLL_DEBUG pck=$GAME_PCK"
( LANG="${SLL_LANGUAGE}.UTF-8" XDG_CONFIG_HOME="$CONFDIR" XDG_DATA_HOME="$CONFDIR" \
  $GODOT_LAUNCH $VERBOSE_ARG $GODOT_AUDIO_ARG --display-driver sdl2 --rendering-driver opengl3 \
  --resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} \
  --main-pack "$GAME_PCK" )
echo "[STS2] exit code: $?"

pm_finish
