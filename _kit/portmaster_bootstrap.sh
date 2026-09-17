#!/usr/bin/env bash
# INPUT:  launcher_platform.sh、XDG_DATA_HOME 与官方约定的 PortMaster control/mod 路径
# OUTPUT: portmaster_discover(), portmaster_init()；全局 controlfolder
# POS:    为设备启动入口按优先级定位 PortMaster 控制目录
# Shared PortMaster control-folder discovery. Sets global $controlfolder.
# Follow the official launch-script template's four-path order:
# https://portmaster.games/packaging.html#the-launchscript-sh

portmaster_discover() {
  XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
  # MiniLoong's path fixer requires assignments on their own lines.
  if [ -d "/opt/system/Tools/PortMaster/" ]; then
    controlfolder="/opt/system/Tools/PortMaster"
  elif [ -d "/opt/tools/PortMaster/" ]; then
    controlfolder="/opt/tools/PortMaster"
  elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
    controlfolder="$XDG_DATA_HOME/PortMaster"
  else
    controlfolder="/roms/ports/PortMaster"
  fi
}

# The installed PortMaster may be stock, firmware-provided or locally
# maintained. Games require its ordinary control/runtime API, not a fork.
portmaster_init() {
  local helper
  portmaster_discover "$1"
  if [ ! -r "$controlfolder/control.txt" ]; then
    echo "[launcher] PortMaster control.txt missing: $controlfolder" >&2
    return 1
  fi
  launcher_platform_display || true
  source "$controlfolder/control.txt"
  if [ -f "$controlfolder/mod_${CFW_NAME:-}.txt" ]; then
    source "$controlfolder/mod_${CFW_NAME}.txt"
  fi
  # Some control/mod scripts end in an optional failed probe. Validate their
  # actual API instead of interpreting that trailing status as a load failure.
  for helper in get_controls pm_platform_helper pm_finish; do
    if ! command -v "$helper" >/dev/null 2>&1; then
      echo "[launcher] PortMaster API missing: $helper" >&2
      return 1
    fi
  done
  launcher_platform_display || true
  get_controls
  launcher_platform_resolution "${2:-640}" "${3:-480}"
}
