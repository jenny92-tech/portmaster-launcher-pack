#!/bin/bash
# PORTMASTER: hollowknight, [中]空洞骑士.sh
# Stage 1: GDScript launcher UI (bootstrap.pck) — 分辨率 / 画面质量 / 按键布局
# Stage 2: unityloader + hk.toml — 字段由 stage 1 的 launch_config.env sed 写入
#
# 仓库里这是个模板:共用逻辑来自 _kit/portmaster_common.sh + launcher_unity_common.sh。
# 部署到设备时 _kit/assemble.sh 会把 KIT 块原地内联成单个自包含脚本(设备上不
# 依赖外部 source)。下面只保留 hk 独有的 stage-1(frt3 UI)和 hk.toml 改写。

PORT_NAME="hollowknight"; LOG_PREFIX="[HK]"

# ── PortMaster preamble (controlfolder 发现 + control.txt) ────────────────
XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "/opt/system/Tools/PortMaster/" ]; then controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then controlfolder="$XDG_DATA_HOME/PortMaster"
else controlfolder="/roms/ports/PortMaster"
fi
source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

GAMEDIR="/$directory/ports/$PORT_NAME"
CONFDIR="$GAMEDIR/conf"
cd "$GAMEDIR"
# Direct fd redirect (no tee): tee buffers in memory and loses the last KB on
# SIGKILL, which is exactly when we need the data most.
exec > "$GAMEDIR/log.txt" 2>&1
echo "$LOG_PREFIX CFW=$CFW_NAME ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} GAMEDIR=$GAMEDIR"
mkdir -p "$CONFDIR" "$GAMEDIR/cache"
HK_RUNTIME_WIDTH="$DISPLAY_WIDTH"
HK_RUNTIME_HEIGHT="$DISPLAY_HEIGHT"

# ── shared helpers (assemble.sh inlines these into the device build) ─────
#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/portmaster_common.sh"
source "$KIT/launcher_unity_common.sh"
#@KIT-END

hk_sync_graphics_resolution() {
  local height="$1"
  local f
  for f in \
    "$GAMEDIR/GraphicsSettings.txt" \
    "$CONFDIR/GraphicsSettings.txt" \
    "$GAMEDIR/gamedata/GraphicsSettings.txt" \
    "$GAMEDIR/gamedata/files/GraphicsSettings.txt"; do
    if [ -f "$f" ]; then
      sed -i "s/^Resolution(Height):.*/Resolution(Height):${height}/" "$f"
      sed -i "s/^NativeDeviceResolution(DO NOT CHANGE):.*/NativeDeviceResolution(DO NOT CHANGE):${height}/" "$f"
    fi
  done
  echo "$LOG_PREFIX GraphicsSettings resolution synced to height=${height}"
}

# ═══════════════ STAGE 1: launcher UI (Godot 3 / frt_3.x) ═══════════════
# bootstrap.pck 是 Godot 3 格式 (与 heishenhua 统一; Godot 4 在 MiniLoong 上起不来)。
# frt 走 PortMaster TrimUI godot 3 标准模式:gptokeyb + hacksdl SDL2 shim,
# 需要 $GAMEDIR/hollowknight.gptk + $GAMEDIR/hacksdl/hacksdl.aarch64.so。
run_launcher_ui frt3 "$GAMEDIR/bootstrap.pck"

# ═══════════════ STAGE 2: patch hk.toml from launcher choices ═══════════
HKL_ENV="$CONFDIR/godot/app_userdata/Hollow Knight Launcher/launch_config.env"
if [ -f "$HKL_ENV" ]; then
  source "$HKL_ENV"
  echo "$LOG_PREFIX env: ${HKL_WIDTH}x${HKL_HEIGHT} texmax=$HKL_TEXMAX swap_ab=$HKL_SWAP_AB swap_xy=$HKL_SWAP_XY"

  # "auto" = 跟随面板 (PortMaster control.txt 的 DISPLAY_WIDTH/HEIGHT)
  if [ "$HKL_WIDTH" = "auto" ]; then
    HKL_WIDTH="$DISPLAY_WIDTH"; HKL_HEIGHT="$DISPLAY_HEIGHT"
    echo "$LOG_PREFIX resolution auto -> ${HKL_WIDTH}x${HKL_HEIGHT}"
  fi
  case "$HKL_WIDTH$HKL_HEIGHT" in
    *[!0-9]*|"") echo "$LOG_PREFIX bad resolution in env, leaving hk.toml as-is" ;;
    *)
      sed -i "s/^displayWidth=.*/displayWidth=${HKL_WIDTH}/" "$GAMEDIR/hk.toml"
      sed -i "s/^displayHeight=.*/displayHeight=${HKL_HEIGHT}/" "$GAMEDIR/hk.toml"
      HK_RUNTIME_WIDTH="$HKL_WIDTH"
      HK_RUNTIME_HEIGHT="$HKL_HEIGHT"
      hk_sync_graphics_resolution "$HK_RUNTIME_HEIGHT"
      ;;
  esac
  # 画面质量 → textureMaxDim: 384/512/720/0 (低/中/高/极致, 与黑神话同参数)。
  case "$HKL_TEXMAX" in
    384|512|720|0) sed -i "s/^textureMaxDim *=.*/textureMaxDim = ${HKL_TEXMAX}/" "$GAMEDIR/hk.toml" ;;
  esac

  # [input.remap] a/b/x/y upsert (awk 自愈,见 launcher_unity_common.sh)
  if [ "$HKL_SWAP_AB" = "on" ]; then A_V=BUTTON_B; B_V=BUTTON_A; else A_V=BUTTON_A; B_V=BUTTON_B; fi
  if [ "$HKL_SWAP_XY" = "on" ]; then X_V=BUTTON_Y; Y_V=BUTTON_X; else X_V=BUTTON_X; Y_V=BUTTON_Y; fi
  apply_button_remap "$GAMEDIR/hk.toml" "$A_V" "$B_V" "$X_V" "$Y_V"
else
  echo "$LOG_PREFIX no launch_config.env — using current hk.toml"
fi

# ── Seed/repair PlayerPrefs so HK skips its first-run video-settings onboarding,
# which hangs on this Android port (no touch / input on that page). VERIFIED
# on-device by minimisation: the gate is the video keys below — the "*Set"
# flags VidOSSet/VidBrightSet mark "video configured", the rest are the values
# that page would set. Existing prefs from old launcher builds may lack those
# keys, so repair that case instead of only handling fresh installs.
HK_PREFS="$CONFDIR/shared_prefs/com.TeamCherry.HollowKnight.v2.playerprefs.json"
hk_write_default_playerprefs() {
  mkdir -p "$CONFDIR/shared_prefs"
  cat > "$HK_PREFS" <<EOF
{
  "bools": {},
  "floats": {
    "VidBrightValue": 20.0,
    "VidOSValue": 0.0
  },
  "ints": {
    "ShaderQuality": 1,
    "VidBrightSet": 1,
    "VidDisplay": 0,
    "VidFC": 1,
    "VidFullscreen": 1,
    "VidOSSet": 1,
    "VidParticles": 1,
    "VidTFR": 400,
    "VidVSync": 0,
    "Screenmanager Fullscreen mode": -1,
    "Screenmanager Resolution Height": ${HK_RUNTIME_HEIGHT},
    "Screenmanager Resolution Width": ${HK_RUNTIME_WIDTH},
    "__UNITY_PLAYERPREFS_VERSION__": 1
  },
  "longs": {},
  "strings": {},
  "version": 1
}
EOF
}

hk_video_prefs_ready() {
  [ -f "$HK_PREFS" ] &&
    grep -q '"VidBrightSet"[[:space:]]*:[[:space:]]*1' "$HK_PREFS" &&
    grep -q '"VidOSSet"[[:space:]]*:[[:space:]]*1' "$HK_PREFS"
}

hk_sync_screenmanager_prefs() {
  [ -f "$HK_PREFS" ] || return 0
  sed -i "s/\"Screenmanager Resolution Height\"[[:space:]]*:[[:space:]]*[0-9-]*/\"Screenmanager Resolution Height\": ${HK_RUNTIME_HEIGHT}/" "$HK_PREFS"
  sed -i "s/\"Screenmanager Resolution Width\"[[:space:]]*:[[:space:]]*[0-9-]*/\"Screenmanager Resolution Width\": ${HK_RUNTIME_WIDTH}/" "$HK_PREFS"
}

if [ ! -f "$HK_PREFS" ]; then
  hk_write_default_playerprefs
  echo "$LOG_PREFIX seeded PlayerPrefs to skip video onboarding (${HK_RUNTIME_WIDTH}x${HK_RUNTIME_HEIGHT})"
elif ! hk_video_prefs_ready; then
  hk_write_default_playerprefs
  echo "$LOG_PREFIX repaired PlayerPrefs video gate"
else
  echo "$LOG_PREFIX PlayerPrefs video gate already set"
fi
hk_sync_screenmanager_prefs

# ═══════════════ STAGE 2: run the game ══════════════════════════════════
run_unity_game hk.toml
