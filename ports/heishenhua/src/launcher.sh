#!/bin/bash
# PORTMASTER: heishenhua, [中]黑神话悟空-像素版.sh
# Stage 1: GDScript launcher UI (bootstrap.pck, Godot 3 / frt) — 画面 / 分辨率 / 按键
# Stage 2: unityloader + config.toml — 字段由 stage 1 的 launch_config.env sed 写入
#
# 仓库里这是个模板:共用逻辑来自 _kit/portmaster_common.sh + launcher_unity_common.sh。
# 部署到设备时 _kit/assemble.sh 把 KIT 块原地内联成单个自包含脚本。下面只保留
# heishenhua 独有的 stage-1(frt3 UI)和 config.toml 改写(分辨率/质量/难度/按键)。

PORT_NAME="heishenhua"; LOG_PREFIX="[HSH]"

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
exec > "$GAMEDIR/log.txt" 2>&1
echo "$LOG_PREFIX CFW=$CFW_NAME ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} GAMEDIR=$GAMEDIR"
mkdir -p "$CONFDIR" "$GAMEDIR/cache"

# ── shared helpers (assemble.sh inlines these into the device build) ─────
#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/portmaster_common.sh"
source "$KIT/launcher_unity_common.sh"
#@KIT-END

# One toml name across all ports; legacy installs are renamed in place.
resolve_port_toml wsm.toml

# ═══════════════ STAGE 1: launcher UI (Godot 3 / frt_3.x) ═══════════════
# bootstrap.pck 是 Godot 3 格式,必须用 frt(godot4 读不了它)→ find_godot_binary frt3。
# frt 走 PortMaster TrimUI godot 3 标准模式:gptokeyb + hacksdl SDL2 shim,
# 需要 $GAMEDIR/heishenhua.gptk + $GAMEDIR/hacksdl/hacksdl.aarch64.so。
run_launcher_ui frt3 "$GAMEDIR/bootstrap.pck"

# ═══════════════ STAGE 2: patch config.toml from launcher choices ══════════
# Godot 用 config/name (中文) 作 app_userdata 目录名,所以这里也是中文路径。
HSH_ENV="$CONFDIR/godot/app_userdata/像素黑神话启动器/launch_config.env"
if [ -f "$HSH_ENV" ]; then
  source "$HSH_ENV"
  echo "$LOG_PREFIX env: ${HSH_WIDTH}x${HSH_HEIGHT} texmax=$HSH_TEXMAX dmg=$HSH_DMG swap_ab=$HSH_SWAP_AB swap_xy=$HSH_SWAP_XY inf_mp=$HSH_INF_MP inf_sta=$HSH_INF_STA inf_wine=$HSH_INF_WINE skill_cd=$HSH_SKILL_CD"

  # 画面质量: launcher UI 的 384/480/720/0 直接写到 textureMaxDim。
  # (中档原 512,部分场景闪退 → 480。仍接受旧的 512 以防旧 env 残留。)
  case "$HSH_TEXMAX" in
    0|384|480|512|720) sed -i "s/^textureMaxDim *=.*/textureMaxDim = ${HSH_TEXMAX}/" "$PORT_TOML" ;;
  esac

  # 重建 config.toml 末尾的 [ui_layout] + [[il2cpp_patch]] (幂等: 先删到尾再追加)
  sed -i -e '/^\[ui_layout\]/,$d' -e '/^\[\[il2cpp_patch\]\]/,$d' "$PORT_TOML"

  # 隐藏安卓虚拟触摸键 (暂停/棍花/重攻击/跳跃/轻攻击/闪避/电话/AK); 喝酒(葫芦)挪到重攻击(重击)空位贴右
  # 注:精魄未解锁时游戏(F_设置技能的显示)自动隐藏其按钮,hook 单 move 名额给葫芦贴右。
  printf '\n[ui_layout]\nclass = "UI_InGame_Main"\nmethod = "Start"\nhide = [0xB8, 0xC0, 0xC8, 0xD8, 0xE0, 0xE8, 0xF8, 0x100]\nmove_from = 0xC8\nmove_to = 0xD0\nright_margin = 70\n' >> "$PORT_TOML"
  echo "$LOG_PREFIX ui_layout: 隐藏触摸键(含电话/AK) + 喝酒→重击位"

  # 减伤: 承伤倍率 =(100-减伤%)/100; 1.0(正常)不写
  case "$HSH_DMG" in
    0.0|0.2|0.4|0.6|0.8)
      printf '\n[[il2cpp_patch]]\nclass = "PlayerController"\nmethod = "BeAttack"\nargc = 1\narg = 0\nfield = 0x10\nmult = %s\n' "$HSH_DMG" >> "$PORT_TOML"
      echo "$LOG_PREFIX 减伤 mult=$HSH_DMG" ;;
  esac

  # 资源无限 (freeze: hook setter, 跑完把 curr 盖回 max)
  hsh_freeze() {  # $1=method $2=curr $3=max $4=type
    printf '\n[[il2cpp_patch]]\nclass = "Player_StateData"\nmethod = "%s"\nargc = 1\narg = -1\nfield = %s\nsrc_field = %s\nmode = "freeze"\ntype = "%s"\n' \
      "$1" "$2" "$3" "$4" >> "$PORT_TOML"
  }
  [ "$HSH_INF_MP" = "on" ]   && { hsh_freeze "set__Curr法力" 0x38 0x34 f32; echo "$LOG_PREFIX 无限法力 on"; }
  [ "$HSH_INF_STA" = "on" ]  && { hsh_freeze "set__Curr气力" 0x44 0x3C f32; echo "$LOG_PREFIX 无限气力 on"; }
  [ "$HSH_INF_WINE" = "on" ] && { hsh_freeze "set__Curr酒"   0x68 0x64 i32; echo "$LOG_PREFIX 无限酒 on"; }

  # 定身术无冷却: 强制 _IsOk_定身术 getter 返回 true
  [ "$HSH_SKILL_CD" = "on" ] && {
    printf '\n[[il2cpp_patch]]\nclass = "Player_StateData"\nmethod = "get__IsOk_定身术"\nargc = 0\nmode = "force_return"\nsetval = 1\n' >> "$PORT_TOML"
    echo "$LOG_PREFIX 定身术无冷却 on"
  }

  # [input.remap] a/b/x/y upsert (awk 自愈,见 launcher_unity_common.sh)
  if [ "$HSH_SWAP_AB" = "on" ]; then A_V=BUTTON_B; B_V=BUTTON_A; else A_V=BUTTON_A; B_V=BUTTON_B; fi
  if [ "$HSH_SWAP_XY" = "on" ]; then X_V=BUTTON_Y; Y_V=BUTTON_X; else X_V=BUTTON_X; Y_V=BUTTON_Y; fi
  apply_button_remap "$PORT_TOML" "$A_V" "$B_V" "$X_V" "$Y_V"
else
  echo "$LOG_PREFIX no launch_config.env — panel resolution, current config.toml otherwise"
fi

# Outside the env branch on purpose: without a launcher UI there is no env, and
# the resolution must still follow this device's panel.
resolve_display_resolution "${HSH_WIDTH:-auto}" "${HSH_HEIGHT:-auto}"
apply_display_resolution "$PORT_TOML"

# ═══════════════ STAGE 2: run the game ══════════════════════════════════
run_unity_game "$PORT_TOML"
