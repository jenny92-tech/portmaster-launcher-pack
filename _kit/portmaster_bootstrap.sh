#!/usr/bin/env bash
# Shared PortMaster control-folder discovery. Sets global $controlfolder.
# The launcher-adjacent PortMaster directory is the strongest signal because
# several frontends execute a temporary renamed copy of the selected script.

portmaster_discover() {
  local script_dir="${1:-$(cd "$(dirname "$0")" && pwd)}"
  XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
  if [ -d "$script_dir/PortMaster/" ]; then controlfolder="$script_dir/PortMaster"
  elif [ -d "/opt/system/Tools/PortMaster/" ]; then controlfolder="/opt/system/Tools/PortMaster"
  elif [ -d "/opt/tools/PortMaster/" ]; then controlfolder="/opt/tools/PortMaster"
  elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then controlfolder="$XDG_DATA_HOME/PortMaster"
  elif [ -d "/mnt/sdcard/roms/ports/PortMaster/" ]; then controlfolder="/mnt/sdcard/roms/ports/PortMaster"
  elif [ -d "/sdcard/roms/ports/PortMaster/" ]; then controlfolder="/sdcard/roms/ports/PortMaster"
  else controlfolder="/roms/ports/PortMaster"
  fi
}
