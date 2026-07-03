#!/bin/bash
# PORTMASTER: terraria, T_泰拉瑞亚.sh
# Stage 1: GDScript launcher UI (bootstrap.pck, Godot 3 / frt) — language / layout.
# Stage 2: unityloader + wsm.toml — only Terraria-specific config lives here.
#
# 仓库里这是个模板:共用逻辑来自 _kit/portmaster_common.sh + launcher_unity_common.sh。
# 部署到设备时 _kit/assemble.sh 把 KIT 块原地内联成单个自包含脚本。

PORT_NAME="terraria"; LOG_PREFIX="[TER]"

# ── PortMaster preamble (controlfolder 发现 + control.txt) ────────────────
XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "/opt/system/Tools/PortMaster/" ]; then controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then controlfolder="$XDG_DATA_HOME/PortMaster"
elif [ -d "/sdcard/roms/ports/PortMaster/" ]; then controlfolder="/sdcard/roms/ports/PortMaster"
else controlfolder="/roms/ports/PortMaster"
fi
source "$controlfolder/control.txt"
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

if [ -n "$directory" ] && [ -d "/$directory/ports/$PORT_NAME" ]; then
  GAMEDIR="/$directory/ports/$PORT_NAME"
else
  GAMEDIR="/sdcard/roms/ports/$PORT_NAME"
fi
CONFDIR="$GAMEDIR/conf"
cd "$GAMEDIR" || exit 1
exec > "$GAMEDIR/log.txt" 2>&1
echo "$LOG_PREFIX CFW=$CFW_NAME ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} GAMEDIR=$GAMEDIR"
mkdir -p "$CONFDIR" "$GAMEDIR/cache/UnityShaderCache" "$GAMEDIR/Players" "$GAMEDIR/Worlds"

# ── shared helpers (assemble.sh inlines these into the device build) ─────
#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/portmaster_common.sh"
source "$KIT/launcher_unity_common.sh"
#@KIT-END

# ═══════════════ STAGE 1: launcher UI (Godot 3 / frt_3.x) ═══════════════
run_launcher_ui frt3 "$GAMEDIR/bootstrap.pck"

apply_terraria_language() {
  local lang="${TER_LANGUAGE:-7}"
  case "$lang" in 1|7|12) ;; *) lang=7 ;; esac

  local cfg="$CONFDIR/config.json"
  mkdir -p "${cfg%/*}" 2>/dev/null || true
  if [ ! -f "$cfg" ]; then
    printf '{\n  "Language": %s\n}\n' "$lang" > "$cfg" 2>/dev/null || true
    echo "$LOG_PREFIX language config created: Language=$lang"
    return 0
  fi

  if grep -q '"Language"' "$cfg"; then
    sed -E 's/"Language"[[:space:]]*:[[:space:]]*[0-9]+/"Language": '"$lang"'/g' "$cfg" > "$cfg.tmp" &&
      mv "$cfg.tmp" "$cfg"
  else
    awk -v lang="$lang" '
      BEGIN { done=0 }
      !done && /\{/ { sub(/\{/, "{\n  \"Language\": " lang ","); done=1 }
      { print }
      END { if (NR == 0) printf "{\n  \"Language\": %s\n}\n", lang }
    ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  fi
  echo "$LOG_PREFIX language config updated: Language=$lang"
}

# ═══════════════ STAGE 2: patch wsm.toml from launcher choices ══════════
TER_ENV="$CONFDIR/godot/app_userdata/泰拉瑞亚启动器/launch_config.env"
if [ -f "$TER_ENV" ]; then
  source "$TER_ENV"
  echo "$LOG_PREFIX env: ${TER_WIDTH}x${TER_HEIGHT} language=$TER_LANGUAGE swap_ab=$TER_SWAP_AB swap_xy=$TER_SWAP_XY"

  if [ "$TER_WIDTH" = "auto" ]; then
    TER_WIDTH="$DISPLAY_WIDTH"; TER_HEIGHT="$DISPLAY_HEIGHT"
    echo "$LOG_PREFIX resolution auto -> ${TER_WIDTH}x${TER_HEIGHT}"
  fi
  case "$TER_WIDTH$TER_HEIGHT" in
    *[!0-9]*|"") echo "$LOG_PREFIX bad resolution in env, leaving wsm.toml as-is" ;;
    *)
      sed -i "s/^displayWidth=.*/displayWidth=${TER_WIDTH}/" "$GAMEDIR/wsm.toml"
      sed -i "s/^displayHeight=.*/displayHeight=${TER_HEIGHT}/" "$GAMEDIR/wsm.toml"
      ;;
  esac

  if [ "$TER_SWAP_AB" = "on" ]; then A_V=BUTTON_B; B_V=BUTTON_A; else A_V=BUTTON_A; B_V=BUTTON_B; fi
  if [ "$TER_SWAP_XY" = "on" ]; then X_V=BUTTON_Y; Y_V=BUTTON_X; else X_V=BUTTON_X; Y_V=BUTTON_Y; fi
  apply_button_remap "$GAMEDIR/wsm.toml" "$A_V" "$B_V" "$X_V" "$Y_V"
else
  echo "$LOG_PREFIX no launch_config.env — using current wsm.toml"
fi

# Start 需要作为 Enter, 这样命名弹窗里能确认。
if grep -q '^start=' "$GAMEDIR/wsm.toml"; then
  sed -i 's/^start=.*/start="ENTER"/' "$GAMEDIR/wsm.toml"
fi

apply_terraria_language

export TER_AUTONAME=1
export TER_AUTONAME_VALUE="${TER_AUTONAME_VALUE:-Jenny}"
export TER_AUTOCREATE_PLAYER=0
export BD_SOFT_INPUT_DEFAULT="${BD_SOFT_INPUT_DEFAULT:-$TER_AUTONAME_VALUE}"
export BD_SOFT_INPUT_FORCE_DEFAULT="${BD_SOFT_INPUT_FORCE_DEFAULT:-0}"
export BD_SOFT_INPUT_CONFIRM_KEYS="${BD_SOFT_INPUT_CONFIRM_KEYS:-ENTER,NUMPAD_ENTER,DPAD_CENTER,BUTTON_A,BUTTON_START,BUTTON_R1,BUTTON_THUMBR}"
export BD_SOFT_INPUT_CANCEL_KEYS="${BD_SOFT_INPUT_CANCEL_KEYS:-BACK,ESCAPE,BUTTON_B,BUTTON_SELECT}"

# ═══════════════ STAGE 2: run the game ══════════════════════════════════
run_unity_game wsm.toml
