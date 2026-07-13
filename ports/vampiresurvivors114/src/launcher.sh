#!/bin/bash
# PORTMASTER: vampiresurvivors114, V_吸血鬼幸存者_114.sh
# 1.14.111 对照端口 — 和 1.15 (vampiresurvivors) 完全分开。资源经同一套
# unity_astc 管线压缩(Mode B: --max-size 1280 --block 8x8 --block-small 6x6),
# 73 个大图重压 ASTC。用来和 1.15 交叉对比 libunity 握手死锁。
#
# 共用逻辑来自 _kit/(assemble.sh 部署时内联)。这里只保留 VS 独有的:
# TrimUI DRM-master 抢占 + .gplay loader 选择。
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

TRIMUI_RUNNER_PID=""


# ── shared helpers (assemble.sh inlines these into the device build) ─────
#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/portmaster_common.sh"
source "$KIT/launcher_unity_common.sh"
#@KIT-END

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

trap release_frontend EXIT INT TERM
acquire_display

resolve_port_toml

run_launcher_ui frt3 "$GAMEDIR/bootstrap.pck"

VS_ENV="$CONFDIR/godot/app_userdata/Vampire Survivors Launcher/launch_config.env"
if [ -f "$VS_ENV" ]; then
  source "$VS_ENV"
  VS_WIDTH=auto
  VS_HEIGHT=auto
  echo "$LOG_PREFIX env: ${VS_WIDTH}x${VS_HEIGHT} swap_ab=$VS_SWAP_AB swap_xy=$VS_SWAP_XY"

  if [ "$VS_SWAP_AB" = "on" ]; then A_V=BUTTON_B; B_V=BUTTON_A; else A_V=BUTTON_A; B_V=BUTTON_B; fi
  if [ "$VS_SWAP_XY" = "on" ]; then X_V=BUTTON_Y; Y_V=BUTTON_X; else X_V=BUTTON_X; Y_V=BUTTON_Y; fi
  apply_button_remap "$PORT_TOML" "$A_V" "$B_V" "$X_V" "$Y_V"
else
  echo "$LOG_PREFIX no launch_config.env — panel resolution, current config.toml otherwise"
fi

# Outside the env branch on purpose: without a launcher UI there is no env, and
# the resolution must still follow this device's panel.
resolve_display_resolution "${VS_WIDTH:-auto}" "${VS_HEIGHT:-auto}"
apply_display_resolution "$PORT_TOML"

# Unity Loader now resolves Android base assets and Play Asset Delivery pack
# assets internally. Keep the launcher focused on UI/config; do not bind
# gamedata/assets or Addressables aa here.

# ── Safe GL defaults ─────────────────────────────────────────────────────
sed -i "s/^glVersionOverride.*/glVersionOverride        = \"OpenGL ES 3.2 Bogodroid\"/" "$PORT_TOML"
sed -i "s/^glMajorVersionOverride.*/glMajorVersionOverride   = 3/" "$PORT_TOML"
sed -i "s/^glMinorVersionOverride.*/glMinorVersionOverride   = 2/" "$PORT_TOML"
sed -i "s/^textureMaxDim *=.*/textureMaxDim = 0/" "$PORT_TOML"

# ── 库路径 + 1GB 掌机 glibc 内存收敛 ─────────────────────────────────────
export XDG_DATA_HOME="$CONFDIR" XDG_CONFIG_HOME="$CONFDIR"
export LD_LIBRARY_PATH="$GAMEDIR/gamedata/lib:$GAMEDIR/gamedata/lib/arm64-v8a:$LD_LIBRARY_PATH"
memory_tuning

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
"$GAMEDIR/$LOADER" "$PORT_TOML"
STATUS=$?
echo "$LOG_PREFIX exited $STATUS"
exit "$STATUS"
