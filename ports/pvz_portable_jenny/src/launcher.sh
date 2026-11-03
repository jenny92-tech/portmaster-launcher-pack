#!/bin/bash
# INPUT:  PortMaster、玩家 main.pak/properties、当前维护的 PvZ Portable 引擎
# OUTPUT: 年度版游戏会话及保留原目录的玩家档案
# POS:    迷你龙 PvZ Portable 的独立 Je- 入口，不携带原游戏资源
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH##*/}" = sh ]; then
    exec /bin/bash "$0" "$@"
fi
# PORTMASTER: pvz_portable.zip, Je-植物大战僵尸年度版[中].sh

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source $controlfolder/control.txt
source $controlfolder/device_info.txt

[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"

get_controls

GAMEDIR="/$directory/ports/pvz_portable_jenny"
BINARY="pvz_portable.${DEVICE_ARCH}"
CONFDIR="$GAMEDIR/conf/"
LIB_DIR="$GAMEDIR/libs.${DEVICE_ARCH}"

> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1
#@BUILD-LOG

cd $GAMEDIR
$ESUDO chmod +x $BINARY

export LD_LIBRARY_PATH="$LIB_DIR:$LD_LIBRARY_PATH"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
export TEXTINPUTINTERACTIVE="Y"
export XDG_DATA_HOME="$CONFDIR"

# LawnStrings.txt in main.pak is UTF-16LE; the game converts it via iconv().
# This firmware ships no glibc gconv modules, so bundle the UTF-16 converter here.
export GCONV_PATH="$GAMEDIR/gconv"

# 手柄光标灵敏度: 数字越大越快, 范围 0.3-3.0, 改完保存重启游戏即可
#export PVZ_CURSOR_SENSITIVITY=1.4
# 手柄自动收阳光范围(像素半径): 数字越大范围越广, 60-640, 改完重启生效
#export PVZ_SUN_RADIUS=220
# 跳关测试: 设为关卡号(1-50)直接跳到该关并解锁全部植物; 设 0 或注释掉=正常进度
# 注意: 会覆盖当前存档进度
#export PVZ_JUMP_LEVEL=46

export MALLOC_CHECK_=0
export GLIBC_TUNABLES="glibc.malloc.tcache_count=0:glibc.malloc.mmap_threshold=16384"

$GPTOKEYB "$BINARY" -c "$GAMEDIR/PvzPortable.gptk" textinput &
export IS_PORTMASTER=1

pm_platform_helper "$BINARY"
./$BINARY -resdir=$GAMEDIR -savedir=$GAMEDIR
pm_finish
