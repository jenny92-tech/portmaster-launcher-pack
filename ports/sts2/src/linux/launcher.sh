#!/bin/bash
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech
#
# PORTMASTER: sts2_lite, Slay the Spire 2.sh
# r3:精简版。关键约束(详见 docs):不用 gptokeyb/EVDEV 独占(迷你龙音量键
# 同设备)、不加 --verbose(g13p0 放大 fault)、DEFSHADER 禁含 rect(整屏黑)。

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "/opt/system/Tools/PortMaster/" ]; then controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then controlfolder="$XDG_DATA_HOME/PortMaster"
elif [ -d "/mnt/sdcard/roms/ports/PortMaster/" ]; then controlfolder="/mnt/sdcard/roms/ports/PortMaster"
else controlfolder="/roms/ports/PortMaster"
fi
source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

PORT_NAME=sts2
LOG_PREFIX="[STS2]"
for candidate in "/$directory/ports/sts2" "/mnt/sdcard/roms/ports/sts2" "/mnt/sdcard/mmcblk1p1/Data/ports/sts2" "/roms/ports/sts2"; do
  [ -d "$candidate" ] && GAMEDIR="$candidate" && break
done
CONFDIR="$GAMEDIR/conf"
mkdir -p "$CONFDIR"
cd "$GAMEDIR" || exit 1

#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../../_kit" && pwd)"
source "$KIT/portmaster_common.sh"
#@KIT-END

export LD_LIBRARY_PATH="/usr/lib:/usr/lib64:${LD_LIBRARY_PATH}"
# 显示:有 wayland socket(迷你龙/weston)走 wayland;否则(吹米等裸 KMS)走
# dummy,由 DSDL2 自带的 KMS+GBM+EGL 直驱面板
if [ -S "/run/wayland-0" ] || [ -S "${XDG_RUNTIME_DIR:-/run}/wayland-0" ]; then
  export SDL_VIDEODRIVER=wayland
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run}"
  export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
else
  export SDL_VIDEODRIVER=dummy
  export SDL_AUDIODRIVER=alsa
fi
export GODOT_DISABLE_PARTICLES=1
export GODOT_DEFSHADER_TYPES="mesh,multimesh"

# 日志:平时全丢;排障时在 GAMEDIR 放 .debug 才落 /tmp
if [ -f "$GAMEDIR/.debug" ]; then RUNLOG=/tmp/sts2_run.log; else RUNLOG=/dev/null; fi

# stage 1:启动器 UI(退出码 42 = Start Game)
[ -f "$GAMEDIR/override.cfg" ] && mv "$GAMEDIR/override.cfg" "$GAMEDIR/override.cfg.gamehide"
( XDG_CONFIG_HOME="$CONFDIR" XDG_DATA_HOME="$CONFDIR" \
  exec -a unityloader ./godot.mono --display-driver sdl2 --rendering-driver opengl3 \
  --resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} \
  --main-pack "$GAMEDIR/bootstrap.pck" ) > "$RUNLOG" 2>&1
launcher_exit=$?
[ -f "$GAMEDIR/override.cfg.gamehide" ] && mv "$GAMEDIR/override.cfg.gamehide" "$GAMEDIR/override.cfg"
if [ "$launcher_exit" != "42" ]; then
  pm_finish
  exit 0
fi

# stage 2:游戏
SLL_ENV="$CONFDIR/godot/app_userdata/STS2 Linux Launcher/launch_config.env"
[ -f "$SLL_ENV" ] && source "$SLL_ENV"
case "$SLL_LANGUAGE" in en_US|zh_CN) ;; *) SLL_LANGUAGE=zh_CN ;; esac
case "$SLL_LANGUAGE" in zh_CN) GAME_LANG=zhs ;; *) GAME_LANG=eng ;; esac
if [ $((DISPLAY_WIDTH * 3)) -eq $((DISPLAY_HEIGHT * 4)) ]; then GAME_ASPECT=four_by_three; else GAME_ASPECT=sixteen_by_nine; fi

DW="${DISPLAY_WIDTH:-960}"; DH="${DISPLAY_HEIGHT:-720}"
for SF in "$CONFDIR"/SlayTheSpire2/*/*/settings.save; do
  [ -f "$SF" ] || continue
  sed -i 's/"language": "[a-z]*"/"language": "'$GAME_LANG'"/' "$SF"
  sed -i 's/"aspect_ratio": "[a-z_]*"/"aspect_ratio": "'$GAME_ASPECT'"/' "$SF"
  # window_size 保险丝:仅超过面板尺寸才纠正(桌面存档遗留会致画面裁切)
  OVER=$(awk -v W="$DW" -v H="$DH" '
    /"window_size"/ {ws=1}
    ws && /"X":/ {v=$0; gsub(/[^0-9]/,"",v); if (v+0 > W) bad=1}
    ws && /"Y":/ {v=$0; gsub(/[^0-9]/,"",v); if (v+0 > H) bad=1; ws=0}
    END {print bad+0}' "$SF")
  if [ "$OVER" = "1" ]; then
    awk -v W="$DW" -v H="$DH" '
      /"window_size"/ {ws=1}
      ws && /"X":/ {sub(/"X": *[0-9]+/, "\"X\": " W)}
      ws && /"Y":/ {sub(/"Y": *[0-9]+/, "\"Y\": " H); ws=0}
      {print}' "$SF" > "$SF.tmp" && mv "$SF.tmp" "$SF"
  fi
done

# gamedata 增量同步(玩家更新游戏文件的通道)
GAMEDATA="$GAMEDIR/gamedata"
if [ -d "$GAMEDATA/data_sts2_linuxbsd_arm64" ]; then
  cp -fu "$GAMEDATA/data_sts2_linuxbsd_arm64/"*.dll  "$GAMEDIR/data_sts2_linuxbsd_arm64/" 2>/dev/null
  cp -fu "$GAMEDATA/data_sts2_linuxbsd_arm64/"*.json "$GAMEDIR/data_sts2_linuxbsd_arm64/" 2>/dev/null
fi

cat > "$GAMEDIR/override.cfg" << 'EOG'
[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"

[dotnet]
project/assembly_name="sts2_compat"
EOG

audio_setup > /dev/null 2>&1
[ -f "$GAMEDIR/.debug" ] && install_exit_trap
pm_platform_helper "godot.mono"

( LANG="${SLL_LANGUAGE}.UTF-8" XDG_CONFIG_HOME="$CONFDIR" XDG_DATA_HOME="$CONFDIR" \
  exec -a unityloader ./godot.mono --display-driver sdl2 --rendering-driver opengl3 \
  --resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} \
  --main-pack "$GAMEDIR/gamedata/pcks/SlayTheSpire2.pck" ) > "$RUNLOG" 2>&1

pm_finish
