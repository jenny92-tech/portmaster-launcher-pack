#!/bin/bash
# PORTMASTER: appmanager, APP Manager.sh
#
# APP Manager — PortMaster 端口管理器。
#
# The UI is self-contained: it starts from the launcher-adjacent PortAppManager
# directory even when PortMaster is missing. Safety-critical filesystem
# mutations remain in this shell and are never performed directly by Lua.
#
# UI writes plan.txt and invokes this script's --apply-plan mode. The helper
# re-validates every path under $ESUDO, then the running LÖVE UI rescans.

PORT_NAME="appmanager"; LOG_PREFIX="[PAM]"
APPLY_ONLY=0
SIZE_ONLY=0
HEALTH_ONLY=0
CHECK_UPDATE_ONLY=0
FORCE_UPDATE_CHECK=0
VALIDATE_ONLY=0
case "${1:-}" in
  --apply-plan) APPLY_ONLY=1 ;;
  --scan-sizes) SIZE_ONLY=1 ;;
  --health-check) HEALTH_ONLY=1 ;;
  --check-pm-update) CHECK_UPDATE_ONLY=1 ;;
  --check-pm-update-force) CHECK_UPDATE_ONLY=1; FORCE_UPDATE_CHECK=1 ;;
  --validate-pending) VALIDATE_ONLY=1 ;;
esac

# ── APP-owned bootstrap ──────────────────────────────────────────────────
# Resolve everything required to draw the repair UI before inspecting the
# managed PortMaster environment. MiniLoong may execute a temporary .port.sh,
# but PAM_SOURCE_DIR keeps the stable directory available to helper processes.
PAM_DIR="${PAM_SOURCE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
PAM_LAUNCHER_SOURCE="$0"
PAM_APP_ROOT="$PAM_DIR/PortAppManager"
[ -n "${PAM_APP_ROOT_OVERRIDE:-}" ] && PAM_APP_ROOT="$PAM_APP_ROOT_OVERRIDE"
PAM_RUNTIME_DIR="$PAM_APP_ROOT/runtime"
PAM_BIN_DIR="$PAM_APP_ROOT/bin"
PAM_SHARE_DIR="$PAM_APP_ROOT/share"

portmaster_discover() {
  local script_dir="$1" xdg_data_home="${XDG_DATA_HOME:-${HOME:-/tmp}/.local/share}"
  if [ -d "$script_dir/PortMaster/" ]; then controlfolder="$script_dir/PortMaster"
  elif [ -d "/opt/system/Tools/PortMaster/" ]; then controlfolder="/opt/system/Tools/PortMaster"
  elif [ -d "/opt/tools/PortMaster/" ]; then controlfolder="/opt/tools/PortMaster"
  elif [ -d "$xdg_data_home/PortMaster/" ]; then controlfolder="$xdg_data_home/PortMaster"
  elif [ -d "/mnt/sdcard/roms/ports/PortMaster/" ]; then controlfolder="/mnt/sdcard/roms/ports/PortMaster"
  elif [ -d "/sdcard/roms/ports/PortMaster/" ]; then controlfolder="/sdcard/roms/ports/PortMaster"
  else controlfolder=""; fi
}
portmaster_discover "$PAM_DIR"
PAM_PORTMASTER_DIR="${PAM_PORTMASTER_DIR_OVERRIDE:-$controlfolder}"

# Safe defaults are enough to start the private runtime and show repair UI.
# A healthy control file may enrich scanning paths, but it is not a bootstrap
# dependency and its input/runtime paths are overwritten with APP-owned ones.
CFW_NAME="${CFW_NAME:-Unknown}"
DISPLAY_WIDTH="${DISPLAY_WIDTH:-960}"
DISPLAY_HEIGHT="${DISPLAY_HEIGHT:-720}"
DEVICE_ARCH="${DEVICE_ARCH:-$(uname -m 2>/dev/null || echo aarch64)}"
DEVICE="${DEVICE:-}"
param_device="${param_device:-}"
ANALOGSTICKS="${ANALOGSTICKS:-2}"
LOWRES="${LOWRES:-N}"
CUR_TTY="${CUR_TTY:-/dev/tty0}"
ESUDO="${ESUDO:-}"
directory="${directory:-}"

pam_detect_profile() {
  PAM_DEVICE_CLASS="unknown-path"
  PAM_DEVICE_NAME="Unknown"
  PAM_TARGET_CONFIRMED="0"
  if [ -f "${PAM_LOONG_VERSION_FILE:-/loong/loong_version}" ]; then
    CFW_NAME="Loong"; PAM_DEVICE_NAME="MiniLoong Pocket One"; PAM_DEVICE_CLASS="tested"
    param_device="miniloong"; DEVICE_ARCH="aarch64"
    directory="${PAM_DIRECTORY_OVERRIDE:-mnt/sdcard/roms}"
    [ -n "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || PAM_PORTMASTER_DIR="/mnt/sdcard/roms/ports/PortMaster"
    PAM_TARGET_CONFIRMED="1"
    DISPLAY_WIDTH="${DISPLAY_WIDTH:-960}"; DISPLAY_HEIGHT="${DISPLAY_HEIGHT:-720}"
  elif [ -d "${PAM_TRIMUI_ROOT:-/mnt/SDCARD}" ] || [ "${CFW_NAME:-}" = "TrimUI" ]; then
    CFW_NAME="${CFW_NAME:-TrimUI}"; PAM_DEVICE_NAME="TrimUI"; PAM_DEVICE_CLASS="tested"
    param_device="trimui"
    directory="${PAM_DIRECTORY_OVERRIDE:-mnt/SDCARD/Data}"
    [ -n "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || PAM_PORTMASTER_DIR="/mnt/SDCARD/Data/ports/PortMaster"
    PAM_TARGET_CONFIRMED="1"
  elif [ -f "$PAM_PORTMASTER_DIR/control.txt" ]; then
    PAM_DEVICE_NAME="${CFW_NAME:-PortMaster device}"; PAM_DEVICE_CLASS="official-untested"
    PAM_TARGET_CONFIRMED="1"
  elif [ -n "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] && [ -n "${PAM_SCRIPTS_DIR_OVERRIDE:-$PAM_DIR}" ]; then
    PAM_DEVICE_NAME="${PAM_DEVICE_NAME_OVERRIDE:-Unverified device}"
    PAM_DEVICE_CLASS="unsupported-known"; PAM_TARGET_CONFIRMED="1"
  fi
  [ -z "${PAM_DEVICE_CLASS_OVERRIDE:-}" ] || PAM_DEVICE_CLASS="$PAM_DEVICE_CLASS_OVERRIDE"
  [ -z "${PAM_DEVICE_NAME_OVERRIDE:-}" ] || PAM_DEVICE_NAME="$PAM_DEVICE_NAME_OVERRIDE"
  [ -z "${PAM_TARGET_CONFIRMED_OVERRIDE:-}" ] || PAM_TARGET_CONFIRMED="$PAM_TARGET_CONFIRMED_OVERRIDE"
  if [ "$PAM_TARGET_CONFIRMED" != "1" ]; then PAM_PORTMASTER_DIR=""; fi
}

pam_detect_profile
[ -z "${PAM_DIRECTORY_OVERRIDE:-}" ] || directory="$PAM_DIRECTORY_OVERRIDE"

# APP-owned input is resolved without executing any managed PortMaster file.
GPTOKEYB="$PAM_BIN_DIR/gptokeyb"
SDL_GAMECONTROLLERCONFIG_FILE="$PAM_SHARE_DIR/gamecontrollerdb.txt"
LOVE_FONT_PATH="$PAM_SHARE_DIR/NotoSansSC-Regular.ttf"
SSL_CERT_FILE="$PAM_SHARE_DIR/cacert.pem"
CURL_CA_BUNDLE="$SSL_CERT_FILE"
pm_platform_helper() { :; }
pm_finish() { :; }

# 脚本目录和游戏目录不一定是同一个。PortMaster 的 shell 侧只导出 $directory 和
# $controlfolder —— "脚本放哪"这个知识只存在于它 Python 侧的 HM_SCRIPTS_DIR, bash
# 拿不到。而各固件确实不一样(实测):
#   迷你龙/多数  gamedirs=/$directory/ports          scripts=同上
#   吹米 TrimUI  gamedirs=/mnt/SDCARD/Data/ports     scripts=/mnt/SDCARD/Roms/PORTS
#   muOS         gamedirs=/mnt/mmc/ports             scripts=/mnt/mmc/ROMS/Ports
#   ROCKNIX      gamedirs=/storage/roms/ports        scripts=/storage/roms/ports_scripts
# 所以脚本目录不去查任何配置, 直接认最强的事实: 本脚本自己就躺在脚本目录里。
SCRIPTS_DIR="${PAM_SCRIPTS_DIR_OVERRIDE:-$PAM_DIR}"
if [ -z "$directory" ]; then
  case "$PAM_DIR" in
    */Roms/PORTS|*/Roms/Ports) directory="${PAM_DIR%/Roms/*}/Data" ;;
    */ROMS/Ports) directory="${PAM_DIR%/ROMS/Ports}/ports" ;;
    */roms/ports_scripts) directory="${PAM_DIR%/roms/ports_scripts}/roms/ports" ;;
    */ports|*/PORTS|*/Ports) directory="$PAM_DIR" ;;
    *) directory="$PAM_DIR" ;;
  esac
fi
case "$directory" in
  */ports|*/PORTS|*/Ports) GAMEDIRS_DIR="/${directory#/}" ;;
  *) GAMEDIRS_DIR="/${directory#/}/ports" ;;
esac
STATE_DIR="$PAM_APP_ROOT/state"
[ -n "${PAM_STATE_DIR_OVERRIDE:-}" ] && STATE_DIR="$PAM_STATE_DIR_OVERRIDE"
GAMEDIR="$PAM_APP_ROOT"
CONFDIR="$STATE_DIR"
controlfolder="$PAM_PORTMASTER_DIR"
if [ -n "$controlfolder" ]; then LIBS_DIR="$controlfolder/libs"
else LIBS_DIR="$PAM_APP_ROOT/state/unavailable-libs"; fi

# 图片目录 PortMaster 完全没定义, 各前端各一套(ES 系用 images/, TrimUI MainUI 用
# Imgs/, 吹米上实测一张图都没有)。探测, 探不到就置空 —— 空 = 不管图片, 而不是
# 拿一个猜的路径去删东西。
IMAGES_DIR=""
for c in "$SCRIPTS_DIR/images" "$SCRIPTS_DIR/Imgs" "$SCRIPTS_DIR/media" "$GAMEDIRS_DIR/images"; do
  if [ -d "$c" ]; then IMAGES_DIR="$c"; break; fi
done
TRASH_DIR="$GAMEDIR/trash"
PLAN_FILE="$CONFDIR/plan.txt"
RESULT_FILE="$CONFDIR/result.txt"
PROGRESS_FILE="$CONFDIR/progress.tsv"
CANCEL_FILE="$CONFDIR/cancel.request"
UPDATE_CACHE_FILE="$CONFDIR/portmaster-update.tsv"
VALIDATION_RESULT_FILE="$CONFDIR/validation-result.tsv"
APPLY_HELPER="$CONFDIR/apply-helper.sh"
SIZE_FILE="$CONFDIR/sizes.tsv"
RUNTIME_CATALOG="$PAM_APP_ROOT/love_ui/runtime_catalog.tsv"
RUNTIME_SOURCE_REF="0d9880ec45269e5dd6df11e5949f07005d5108d8"
RUNTIME_DIRECT_BASE="https://raw.githubusercontent.com/PortsMaster/PortMaster-New/$RUNTIME_SOURCE_REF/runtimes"
RUNTIME_ROUTE_SOURCE="https://github.com/NapNeko/NapCat-Mac-Installer/blob/c30e49595d7ce1887edc9e8eb5d020b6846ef137/NapCatInstaller/Utils.swift#L212"
PAM_RELEASE_BASE="${PAM_RELEASE_BASE:-https://github.com/jenny92-tech/PortMaster-GUI/releases/latest/download}"
RUNTIME_CUSTOM_ROUTES="7632298ac516bdb10737bfa1ee78d898c330af15e42eedb35f14059b3e259caf692976dc440f46a379d00aa26d36c584c80fbded0329f6adca0392cb9b76fb5bfa6de2921a1152db3c38d2a86c515e834a0a4ae229c064b11009c6dd8e58b0b4013ea84ccd00c185cc3cfb5180219393571951dd293185bf48d406d50d104be338d9608d1753d48cd8"
RUNTIME_GITHUB_ROUTES="7435399fda45e4ec1c2da0b5b43f9fc6d57fae55f02894af47195b82776ed6b1612f6d964d0346a274d264a03621d4de8b1daaab7529f6adca0392cb9b69f410ea27f698191d48855b3589bb742802d909015ebd6ace63bd1d57da95c67dbbaf073df51f915bc784c63cff5aa7379490431c0d86273efba34cd34c89184d05f172d76d960e189784d546a7a51831c30fdd0ac7f6c462e0460541cddc58094f9f362d8c9955d73a964a0a5eeb289bdb9a0505d58adb41b9bc205c9040d919b690d46ee0794850c1904b504b933229b09d5eca40e8520e56ec1db2dfde0f1d8f91d410b0413554dc4e8404dd82ae76987a0e00d0c4081e5fcb0cc2a3d35bd90685591b2cc81ef88c864e468a91d014974c2a499856cd6edc842c529b38555891865f1d46fb4bdda3de4cc2029e5d02d0cc12f4889a4a428695e46982502655c61fce10c3b838088b7401619a975b017ca7468aa2ce58db558c602bbac60df2859e5219d47583779f572b569412890ba4ae39468534050a9b8c76ff7ff0028fadcc50b54ca63e3aa19651b78789084bfa6ee976965e3e0fc156375aa0b0205e8f24414c9df339ea6fff18d3bc8147d4b5dc2e32a2c009a6c3ca2371e57ff8399b4c3a43dc6b3731aeee3c5d88180213b2ef68bf2ca616ddbf853bf5bda92a2fa99a15ff85132869ed73ee31d8183040ae2f2b21aca462419d785cf3b6e76ff225a256d2bce32cf1bfa62770a3ca1afeac332f7f9777ed7b8b40913af16a3e2caeb73843de092af4bee56cb36fee0dbb41e724ffa7f87575a5d46090a87e277aaf78f309977bdb61a133656fbfbd3056b90c70ffa3e668eb62ec73f844b137e4a5cc3e22b23039d6f33a3361ab7ef566fa6ed133b57a234ebca40cb2bb5875b8b1e725f97fd26ea742f842ffb8be2221c06b6987b0273e75e77c1a15f368d713a2653638a39653e9a30e68f1a5fa21fe81d803ed51f33ce0fae141499638308bbc74726ce241025af271da7ce0732338e6c004beb00978a0f1e01b8393c934b40bb46efcaa38025e863c2dc2ef2e3f6d974a1647a16bd071c8710ec498d74ee1f30929e6ae951bc8eddd65e94dfc7eb4d75e0d089138778cbe6adc40db481350"

mkdir -p "$PAM_APP_ROOT" "$CONFDIR" "$TRASH_DIR"
cd "$PAM_APP_ROOT" || exit 1
if [ "$HEALTH_ONLY" = "1" ]; then
  :
elif [ "$APPLY_ONLY" = "1" ] || [ "$SIZE_ONLY" = "1" ] || [ "$CHECK_UPDATE_ONLY" = "1" ] || [ "$VALIDATE_ONLY" = "1" ]; then
  exec >> "$GAMEDIR/log.txt" 2>&1
else
  exec > "$GAMEDIR/log.txt" 2>&1
fi

if [ "$APPLY_ONLY" != "1" ] && [ "$SIZE_ONLY" != "1" ] && [ "$CHECK_UPDATE_ONLY" != "1" ] && [ "$VALIDATE_ONLY" != "1" ]; then
  helper_ready=0
  # MiniLoong 用临时 .port.sh 启动，这个文件可能在执行期间就被
  # 前端移除。Bash 仍在 fd 255 持有已打开的脚本；最后再回退到目录里
  # 稳定的 APP Manager.sh，不假设任何一个文件名在这一瞬间必然存在。
  for helper_source in "$PAM_LAUNCHER_SOURCE" "/proc/$$/fd/255" "$PAM_DIR/APP Manager.sh"; do
    [ -f "$helper_source" ] || continue
    [ "$helper_source" = "$APPLY_HELPER" ] && continue
    if cp -f "$helper_source" "$APPLY_HELPER" 2>/dev/null; then
      helper_ready=1
      break
    fi
  done
  # 设备上已有一份完整 helper 时绝不因临时源文件消失就把
  # apply_script 清空。但必须检查函数标记，不复用截断的坏文件。
  if [ "$helper_ready" = "0" ] && grep -q '^apply_plan()' "$APPLY_HELPER" 2>/dev/null; then
    helper_ready=1
  fi
  if [ "$helper_ready" = "1" ]; then
    chmod +x "$APPLY_HELPER" 2>/dev/null
  else
    APPLY_HELPER=""
  fi
fi
[ "$HEALTH_ONLY" = "1" ] || echo "$LOG_PREFIX CFW=$CFW_NAME ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} scripts=$SCRIPTS_DIR gamedirs=$GAMEDIRS_DIR"

pam_core_health() {
  [ -d "$PAM_PORTMASTER_DIR" ] || { printf missing; return; }
  [ -f "$PAM_PORTMASTER_DIR/control.txt" ] || { printf damaged; return; }
  [ -f "$PAM_PORTMASTER_DIR/device_info.txt" ] || { printf damaged; return; }
  [ -f "$PAM_PORTMASTER_DIR/funcs.txt" ] || { printf damaged; return; }
  [ -f "$PAM_PORTMASTER_DIR/pugwash" ] || [ -f "$PAM_PORTMASTER_DIR/harbourmaster" ] || {
    printf damaged; return;
  }
  printf healthy
}

pam_core_version() {
  if [ -s "$PAM_PORTMASTER_DIR/version" ]; then
    head -n 1 "$PAM_PORTMASTER_DIR/version" | tr -cd 'A-Za-z0-9._-'
  elif [ -f "$PAM_PORTMASTER_DIR/pugwash" ]; then
    sed -n "s/^PORTMASTER_VERSION = '\([^']*\)'.*/\1/p" "$PAM_PORTMASTER_DIR/pugwash" | head -n 1
  fi
}

# ── 环境 → env.json (LÖVE UI 的唯一事实来源) ───────────────────────────
# $directory / $controlfolder 只有 shell 知道 (control.txt 注入), 而扫描器必须
# 拿它们去展开脚本里的 GAMEDIR="/$directory/ports/$PORT_NAME"。喂不进去, 一半
# 的脚本就解析不出目录。
json_escape() {
  local value="${1-}"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

write_env() {
  # busybox 的 df 不认 -B1 (吹米上实测吐空), 用可移植的 -k 再乘回去。
  local free update_checked=0 update_status="unknown" update_latest="" env_tmp="$CONFDIR/env.json.tmp.$$"
  free=$(df -k "$SCRIPTS_DIR" 2>/dev/null | awk 'NR==2 {print $4 * 1024}')
  case "$free" in ''|*[!0-9]*) free=0 ;; esac
  if [ -s "$UPDATE_CACHE_FILE" ]; then
    IFS=$'\t' read -r update_checked update_status update_latest < "$UPDATE_CACHE_FILE" || true
    case "$update_checked" in ""|*[!0-9]*) update_checked=0 ;; esac
    case "$update_status" in ok|error) ;; *) update_status="unknown" ;; esac
    case "$update_latest" in ""|*[!A-Za-z0-9._-]*) update_latest="" ;; esac
  fi
  cat > "$env_tmp" <<EOF
{
  "controlfolder": "$(json_escape "$controlfolder")",
  "scripts_dir": "$(json_escape "$SCRIPTS_DIR")",
  "gamedirs_dir": "$(json_escape "$GAMEDIRS_DIR")",
  "images_dir": "$(json_escape "$IMAGES_DIR")",
  "libs_dir": "$(json_escape "$LIBS_DIR")",
  "gamedir": "$(json_escape "$GAMEDIR")",
  "directory": "$(json_escape "$directory")",
  "home": "$(json_escape "$HOME")",
  "cfw": "$(json_escape "$CFW_NAME")",
  "free_bytes": $free,
  "display_width": "$(json_escape "${DISPLAY_WIDTH:-}")",
  "display_height": "$(json_escape "${DISPLAY_HEIGHT:-}")",
  "device_arch": "$(json_escape "${DEVICE_ARCH:-}")",
  "device": "$(json_escape "${DEVICE:-}")",
  "param_device": "$(json_escape "${param_device:-}")",
  "analog_sticks": "$(json_escape "${ANALOGSTICKS:-}")",
  "lowres": "$(json_escape "${LOWRES:-}")",
  "cur_tty": "$(json_escape "${CUR_TTY:-}")",
  "sdl_controller_file": "$(json_escape "${SDL_GAMECONTROLLERCONFIG_FILE:-}")",
  "esudo": "$(json_escape "${ESUDO:-}")",
  "gptokeyb": "$(json_escape "${GPTOKEYB:-}")",
  "path": "$(json_escape "${PATH:-}")",
  "ld_library_path": "$(json_escape "${LD_LIBRARY_PATH:-}")",
  "xdg_config_home": "$(json_escape "${XDG_CONFIG_HOME:-}")",
  "xdg_data_home": "$(json_escape "${XDG_DATA_HOME:-}")",
  "plan_file": "$(json_escape "$PLAN_FILE")",
  "result_file": "$(json_escape "$RESULT_FILE")",
  "progress_file": "$(json_escape "$PROGRESS_FILE")",
  "cancel_file": "$(json_escape "$CANCEL_FILE")",
  "apply_script": "$(json_escape "$APPLY_HELPER")",
  "size_file": "$(json_escape "$SIZE_FILE")",
  "runtime_catalog_file": "$(json_escape "$RUNTIME_CATALOG")",
  "app_root": "$(json_escape "$PAM_APP_ROOT")",
  "portmaster_health": "$(json_escape "$(pam_core_health)")",
  "portmaster_version": "$(json_escape "$(pam_core_version)")",
  "portmaster_target": "$(json_escape "$PAM_PORTMASTER_DIR")",
  "device_name": "$(json_escape "$PAM_DEVICE_NAME")",
  "device_class": "$(json_escape "$PAM_DEVICE_CLASS")",
  "target_confirmed": "$(json_escape "$PAM_TARGET_CONFIRMED")",
  "pending_install": "$(json_escape "$CONFDIR/pending-install.tsv")",
  "validation_result_file": "$(json_escape "$VALIDATION_RESULT_FILE")",
  "update_cache_file": "$(json_escape "$UPDATE_CACHE_FILE")",
  "update_checked": $update_checked,
  "update_status": "$(json_escape "$update_status")",
  "portmaster_latest": "$(json_escape "$update_latest")",
  "ignore_dirs": ["PortMaster", "images", "$(json_escape "$PORT_NAME")"],
  "ignore_scripts": ["PortMaster.sh", "$(json_escape "$(basename "$PAM_LAUNCHER_SOURCE")")", ".port.sh"],
  "self_port": "$(json_escape "$PORT_NAME")"
}
EOF
  mv -f -- "$env_tmp" "$CONFDIR/env.json"
}

# ── 执行 UI 产出的行动清单 ───────────────────────────────────────────────
# 首页卸载和残留清理一律是 mv 进回收站；只有回收站里用户明确
# 确认“彻底删除选中”才会 rm -rf 已做过边界校验的选中项。目录名跟脚本名对不上
# (A-文件管理器.sh 指向的是 FileManager/), 判定是靠解析脚本推出来的, 在真卡上
# 跑够之前, 不做不可逆的事。
restore_one() {
  local item="$1" target="$2" kind="$3" base
  base=$(basename "$item")

  # 回收站是用户可写目录，恢复时仍要重做边界检查，不能把人工塞入的
  # 内容写成 PortMaster 或 APP Manager 本身。
  case "$kind" in
    scripts)
      if [[ "$base" != *.sh ]] || [ "$base" = "PortMaster.sh" ] ||
         [ "$base" = ".port.sh" ] || [ "$base" = "APP Manager.sh" ]; then
        printf 'FAIL\trestore\t%s\n' "$base" >> "$RESULT_FILE"
        return
      fi
      ;;
    data)
      if [ "$base" = "$PORT_NAME" ] || [ "$base" = "PortMaster" ] || [ "$base" = "images" ]; then
        printf 'FAIL\trestore\t%s\n' "$base" >> "$RESULT_FILE"
        return
      fi
      ;;
    images)
      if [ -z "$target" ]; then
        printf 'FAIL\trestore\t%s\n' "$base" >> "$RESULT_FILE"
        return
      fi
      ;;
    *)
      printf 'FAIL\toperation\n' >> "$RESULT_FILE"
      return
      ;;
  esac

  # 绝不覆盖已有内容：删除后用户可能已重新安装了同名端口。
  if [ -e "$target/$base" ] || [ -L "$target/$base" ]; then
    printf 'FAIL\trestore\t%s\n' "$base" >> "$RESULT_FILE"
    echo "$LOG_PREFIX restore kept in trash, destination exists: $base"
    return
  fi
  if $ESUDO mkdir -p "$target" && $ESUDO mv -- "$item" "$target/$base"; then
    echo "$LOG_PREFIX restored: $base"
  else
    printf 'FAIL\trestore\t%s\n' "$base" >> "$RESULT_FILE"
  fi
}

restore_bucket() {
  local source="$1" target="$2" kind="$3" item
  [ -d "$source" ] || return
  if [ -L "$source" ]; then
    printf 'FAIL\trestore\t%s\n' "$(basename "$source")" >> "$RESULT_FILE"
    return
  fi
  for item in "$source"/* "$source"/.[!.]* "$source"/..?*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    # 旧版在 SH/Data 同根的 MiniLoong 上可能把 Data 目录错放进
    # scripts 桶。目录不可能是 SH，恢复时安全地纠正回 Data 根。
    if [ "$kind" = "scripts" ] && [ -d "$item" ] && [ ! -L "$item" ]; then
      restore_one "$item" "$GAMEDIRS_DIR" data
    else
      restore_one "$item" "$target" "$kind"
    fi
  done
  $ESUDO rmdir -- "$source" 2>/dev/null || true
}

# 精确放回 UI 选中的一个回收站直接项。plan.txt 会被再次做边界和层级校验：
# 只接受 trash/<批次>/<来源>/<项目>、旧格式 trash/<批次>/<项目>，以及旧版遗留的
# trash/<项目>；更深层路径和任何逃逸路径都拒绝。
restore_selected_item() {
  local source="$1" rel parent bucket batch kind target cleanup_parent="" cleanup_batch=""

  case "$source" in
    "$TRASH_DIR"/*) ;;
    *)
      printf 'FAIL\toperation\n' >> "$RESULT_FILE"
      echo "$LOG_PREFIX rejected restore path: $source"
      return
      ;;
  esac
  rel=${source#"$TRASH_DIR"/}
  case "$rel" in
    ""|/*|../*|*/../*|*/..|./*|*/./*|*/.|*//*)
      printf 'FAIL\toperation\n' >> "$RESULT_FILE"
      echo "$LOG_PREFIX rejected restore path: $source"
      return
      ;;
  esac
  if [ ! -e "$source" ] && [ ! -L "$source" ]; then
    echo "$LOG_PREFIX already restored: $(basename "$source")"
    return
  fi

  parent=$(dirname "$source")
  bucket=$(basename "$parent")
  batch=$(dirname "$parent")
  if { [ "$bucket" = "scripts" ] || [ "$bucket" = "images" ] || [ "$bucket" = "data" ]; } &&
     [ "$(dirname "$batch")" = "$TRASH_DIR" ]; then
    # 新格式：批次和来源桶都必须是真目录，不能借软链接跳出回收站。
    if [ ! -d "$batch" ] || [ -L "$batch" ] || [ ! -d "$parent" ] || [ -L "$parent" ]; then
      printf 'FAIL\toperation\n' >> "$RESULT_FILE"
      return
    fi
    kind="$bucket"
    if [ "$kind" = "scripts" ] && [ -d "$source" ] && [ ! -L "$source" ]; then
      kind="data"
    fi
    cleanup_parent="$parent"
    cleanup_batch="$batch"
  elif [ "$(dirname "$parent")" = "$TRASH_DIR" ]; then
    # 旧格式扁平批次。
    if [ ! -d "$parent" ] || [ -L "$parent" ]; then
      printf 'FAIL\toperation\n' >> "$RESULT_FILE"
      return
    fi
    cleanup_batch="$parent"
    if [ -d "$source" ] && [ ! -L "$source" ]; then kind="data"
    elif [[ "$(basename "$source")" = *.sh ]]; then kind="scripts"
    else kind="images"
    fi
  elif [ "$parent" = "$TRASH_DIR" ]; then
    # 极旧版本可能把文件直接放在 trash 根目录。
    if [ -d "$source" ] && [ ! -L "$source" ]; then kind="data"
    elif [[ "$(basename "$source")" = *.sh ]]; then kind="scripts"
    else kind="images"
    fi
  else
    printf 'FAIL\toperation\n' >> "$RESULT_FILE"
    echo "$LOG_PREFIX rejected nested restore path: $source"
    return
  fi

  case "$kind" in
    scripts) target="$SCRIPTS_DIR" ;;
    images)  target="$IMAGES_DIR" ;;
    data)    target="$GAMEDIRS_DIR" ;;
  esac
  restore_one "$source" "$target" "$kind"
  if [ ! -e "$source" ] && [ ! -L "$source" ]; then
    [ -z "$cleanup_parent" ] || $ESUDO rmdir -- "$cleanup_parent" 2>/dev/null || true
    [ -z "$cleanup_batch" ] || $ESUDO rmdir -- "$cleanup_batch" 2>/dev/null || true
  fi
}


# 永久删除 UI 选中的一个回收站直接项。边界和层级规则与单项
# 放回完全一致：只接受新格式来源桶的项目、旧批次的项目以及极旧的
# trash/<项目>，更深层内容和任何逃逸路径都拒绝。
delete_selected_item() {
  local source="$1" rel parent bucket batch cleanup_parent="" cleanup_batch="" base

  case "$source" in
    "$TRASH_DIR"/*) ;;
    *)
      printf 'FAIL\toperation\n' >> "$RESULT_FILE"
      echo "$LOG_PREFIX rejected delete path: $source"
      return
      ;;
  esac
  rel=${source#"$TRASH_DIR"/}
  case "$rel" in
    ""|/*|../*|*/../*|*/..|./*|*/./*|*/.|*//*)
      printf 'FAIL\toperation\n' >> "$RESULT_FILE"
      echo "$LOG_PREFIX rejected delete path: $source"
      return
      ;;
  esac
  if [ ! -e "$source" ] && [ ! -L "$source" ]; then
    echo "$LOG_PREFIX already permanently deleted: $(basename "$source")"
    return
  fi

  base=$(basename "$source")
  parent=$(dirname "$source")
  bucket=$(basename "$parent")
  batch=$(dirname "$parent")
  # UI 永远只会提交批次内的直接 Item，不会提交整个批次或
  # scripts/data/images 容器。即使 plan.txt 被损坏，也必须拒绝这两类
  # 扩大删除范围的路径。回收站根下的极旧直接文件/软链仍可删除。
  if [ "$parent" = "$TRASH_DIR" ] && [ -d "$source" ] && [ ! -L "$source" ]; then
    printf 'FAIL\toperation\n' >> "$RESULT_FILE"
    echo "$LOG_PREFIX rejected trash container delete: $source"
    return
  fi
  if [ "$(dirname "$parent")" = "$TRASH_DIR" ] && [ -d "$source" ] && [ ! -L "$source" ]; then
    case "$base" in
      scripts|images|data)
        printf 'FAIL\toperation\n' >> "$RESULT_FILE"
        echo "$LOG_PREFIX rejected trash bucket delete: $source"
        return
        ;;
    esac
  fi
  if { [ "$bucket" = "scripts" ] || [ "$bucket" = "images" ] || [ "$bucket" = "data" ]; } &&
     [ "$(dirname "$batch")" = "$TRASH_DIR" ]; then
    if [ ! -d "$batch" ] || [ -L "$batch" ] || [ ! -d "$parent" ] || [ -L "$parent" ]; then
      printf 'FAIL\toperation\n' >> "$RESULT_FILE"
      return
    fi
    cleanup_parent="$parent"
    cleanup_batch="$batch"
  elif [ "$(dirname "$parent")" = "$TRASH_DIR" ]; then
    if [ ! -d "$parent" ] || [ -L "$parent" ]; then
      printf 'FAIL\toperation\n' >> "$RESULT_FILE"
      return
    fi
    cleanup_batch="$parent"
  elif [ "$parent" != "$TRASH_DIR" ]; then
    printf 'FAIL\toperation\n' >> "$RESULT_FILE"
    echo "$LOG_PREFIX rejected nested delete path: $source"
    return
  fi

  if $ESUDO rm -rf -- "$source"; then
    echo "$LOG_PREFIX permanently deleted: $base"
    [ -z "$cleanup_parent" ] || $ESUDO rmdir -- "$cleanup_parent" 2>/dev/null || true
    [ -z "$cleanup_batch" ] || $ESUDO rmdir -- "$cleanup_batch" 2>/dev/null || true
  else
    printf 'FAIL\tdelete\t%s\n' "$base" >> "$RESULT_FILE"
  fi
}

# ── Runtime repair ─────────────────────────────────────────────────────
# The official catalog maps the canonical launcher name (the filename kept in
# controlfolder/libs) to architecture-specific files in PortMaster-New. Some
# large files are split; they are downloaded in order and joined before the
# canonical .squashfs is atomically installed.
RUNTIME_PROGRESS_COUNT=0
RUNTIME_PROGRESS_INDEX=0
RUNTIME_PROGRESS_TOTAL_BYTES=0
RUNTIME_PROGRESS_DONE_BYTES=0
RUNTIME_PROGRESS_RUNTIME=""
RUNTIME_PROGRESS_SOURCE_BASE=0
RUNTIME_PROGRESS_DETAIL=""
PORTMASTER_PROGRESS=0

runtime_progress_write() {
  local phase="${1:-preparing}" current="${2:-0}" speed="${3:-0}" detail="${4:-}" tmp
  [ "$RUNTIME_PROGRESS_COUNT" -gt 0 ] || return 0
  case "$current" in ""|*[!0-9]*) current=0 ;; esac
  case "$speed" in ""|*[!0-9]*) speed=0 ;; esac
  if [ "$RUNTIME_PROGRESS_TOTAL_BYTES" -gt 0 ] && [ "$current" -gt "$RUNTIME_PROGRESS_TOTAL_BYTES" ]; then
    current=$RUNTIME_PROGRESS_TOTAL_BYTES
  fi
  detail=${detail//$'\t'/ }; detail=${detail//$'\r'/ }; detail=${detail//$'\n'/ }
  tmp="$PROGRESS_FILE.tmp.$$"
  printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$RUNTIME_PROGRESS_RUNTIME" "$RUNTIME_PROGRESS_INDEX" "$RUNTIME_PROGRESS_COUNT" \
    "$current" "$RUNTIME_PROGRESS_TOTAL_BYTES" "$speed" "$detail" > "$tmp" &&
    mv -f -- "$tmp" "$PROGRESS_FILE"
}

runtime_progress_prepare_plan() {
  local kind arg bytes
  RUNTIME_PROGRESS_COUNT=0
  RUNTIME_PROGRESS_INDEX=0
  RUNTIME_PROGRESS_TOTAL_BYTES=0
  RUNTIME_PROGRESS_DONE_BYTES=0
  PORTMASTER_PROGRESS=0
  while IFS=$'\t' read -r kind arg; do
    if [ "$kind" = "INSTALL_RUNTIME" ]; then
      RUNTIME_PROGRESS_COUNT=$((RUNTIME_PROGRESS_COUNT + 1))
      bytes=$(runtime_expected_size "$arg")
      case "$bytes" in ""|*[!0-9]*) bytes=0 ;; esac
      RUNTIME_PROGRESS_TOTAL_BYTES=$((RUNTIME_PROGRESS_TOTAL_BYTES + bytes))
    elif [ "$kind" = "INSTALL_PORTMASTER" ] && [ "$arg" = "stable" ]; then
      RUNTIME_PROGRESS_COUNT=1
      RUNTIME_PROGRESS_TOTAL_BYTES=100
      RUNTIME_PROGRESS_RUNTIME="PortMaster"
      PORTMASTER_PROGRESS=1
    fi
  done < "$PLAN_FILE"
  if [ "$RUNTIME_PROGRESS_COUNT" -gt 0 ]; then
    runtime_progress_write preparing 0 0 "Preparing operation"
  fi
}

runtime_arch() {
  local arch
  arch=$(printf '%s' "${DEVICE_ARCH:-$(uname -m 2>/dev/null)}" | tr '[:upper:]' '[:lower:]')
  case "$arch" in
    arm64|armv8) echo aarch64 ;;
    armv7|armv7l) echo armhf ;;
    amd64) echo x86_64 ;;
    *) echo "$arch" ;;
  esac
}

runtime_sources() {
  local runtime="$1" arch
  arch=$(runtime_arch)
  [ -f "$RUNTIME_CATALOG" ] || return 1
  awk -F '\t' -v runtime="$runtime" -v arch="$arch" \
    '$1 == runtime && $2 == arch { print $3; exit }' "$RUNTIME_CATALOG"
}

runtime_expected_size() {
  local runtime="$1" arch
  arch=$(runtime_arch)
  [ -f "$RUNTIME_CATALOG" ] || return 1
  awk -F '\t' -v runtime="$runtime" -v arch="$arch" \
    '$1 == runtime && $2 == arch { print $4; exit }' "$RUNTIME_CATALOG"
}

runtime_source_sizes() {
  local runtime="$1" arch
  arch=$(runtime_arch)
  [ -f "$RUNTIME_CATALOG" ] || return 1
  awk -F '\t' -v runtime="$runtime" -v arch="$arch" \
    '$1 == runtime && $2 == arch { print $5; exit }' "$RUNTIME_CATALOG"
}

runtime_valid_source() {
  local source="$1"
  case "$source" in
    ""|*[!A-Za-z0-9._+-]*|.*|*..*) return 1 ;;
  esac
  case "$source" in *.squashfs|*.squashfs.part.[0-9][0-9][0-9]) return 0 ;; esac
  return 1
}

runtime_blob_decode() {
  local hex="$1" key=(91 37 204 113 18 167 62 209 84 9 231)
  local i=0 pair value oct ch out=""
  while [ -n "$hex" ]; do
    pair="${hex:0:2}"; hex="${hex:2}"
    value=$((16#$pair ^ key[i % ${#key[@]}] ^ ((i * 29 + 71) & 255)))
    printf -v oct '%03o' "$value"
    printf -v ch "\\$oct"
    out+="$ch"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

runtime_proxy_candidates() {
  local custom_rows github_rows format name base route_index=0
  if [ "${PAM_RUNTIME_CUSTOM_PROXIES+x}" = "x" ]; then
    custom_rows="$PAM_RUNTIME_CUSTOM_PROXIES"
  else
    custom_rows=$(runtime_blob_decode "$RUNTIME_CUSTOM_ROUTES") || return 1
  fi
  while IFS='|' read -r format name base; do
    [ -n "$format" ] && [ -n "$name" ] && [ -n "$base" ] || continue
    case "$format" in custom|full|jsdelivr) ;; *) continue ;; esac
    case "$base" in https://*) ;; *) continue ;; esac
    printf '%s\t%s\t%s\n' "$format" "$name" "${base%/}"
  done <<< "$custom_rows"

  if [ "${PAM_RUNTIME_PROXIES+x}" = "x" ]; then
    github_rows="$PAM_RUNTIME_PROXIES"
  else
    github_rows=$(runtime_blob_decode "$RUNTIME_GITHUB_ROUTES") || return 1
  fi
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    case "$base" in https://*) ;; *) continue ;; esac
    route_index=$((route_index + 1)); name="r$route_index"
    printf 'github\t%s\t%s\n' "$name" "${base%/}"
  done <<< "$github_rows"
}

runtime_url() {
  local format="$1" base="$2" source="$3"
  case "$format" in
    direct)
      printf '%s/%s\n' "$RUNTIME_DIRECT_BASE" "$source"
      ;;
    github|full)
      printf '%s/https://github.com/PortsMaster/PortMaster-New/raw/%s/runtimes/%s\n' \
        "${base%/}" "$RUNTIME_SOURCE_REF" "$source"
      ;;
    custom)
      printf '%s/PortsMaster/PortMaster-New/raw/%s/runtimes/%s\n' \
        "${base%/}" "$RUNTIME_SOURCE_REF" "$source"
      ;;
    jsdelivr)
      printf '%s/PortsMaster/PortMaster-New@%s/runtimes/%s\n' \
        "${base%/}" "$RUNTIME_SOURCE_REF" "$source"
      ;;
    *) return 1 ;;
  esac
}

runtime_has_magic() {
  [ -f "$1" ] && [ "$(LC_ALL=C head -c 4 "$1" 2>/dev/null)" = "hsqs" ]
}

runtime_prepare_downloader() {
  local candidate
  candidate="$PAM_BIN_DIR/curl-portable"
  if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
    RUNTIME_CURL="$candidate"
    return 0
  fi
  RUNTIME_CURL=""
  return 1
}

pam_stable_version_from_json() {
  awk '
    /"stable"[[:space:]]*:/ { stable=1; next }
    stable && /"version"[[:space:]]*:/ {
      line=$0
      sub(/^[^:]*:[[:space:]]*"/, "", line)
      sub(/".*/, "", line)
      print line
      exit
    }
  ' "$1"
}

pam_cache_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf 0
}

pam_check_update() {
  local now mtime tmp latest status="error"
  now=$(date +%s 2>/dev/null || printf 0)
  mtime=$(pam_cache_mtime "$UPDATE_CACHE_FILE")
  case "$now:$mtime" in *[!0-9:]*|:) mtime=0 ;; esac
  if [ "$FORCE_UPDATE_CHECK" != "1" ] && [ "$mtime" -gt 0 ] && [ $((now - mtime)) -lt 86400 ]; then return 0; fi

  tmp="$CONFDIR/.portmaster-version.$$"
  rm -f -- "$tmp"
  rm -f -- "$CANCEL_FILE"
  if [ -n "${PAM_VERSION_URL:-}" ] && runtime_prepare_downloader; then
    "$RUNTIME_CURL" -fsSL --connect-timeout 8 --max-time 20 -o "$tmp" "$PAM_VERSION_URL" 2>/dev/null || true
  elif pm_select_release_routes; then
    pm_download_asset version.json "$tmp" 0 0 || true
  fi
  latest=$(pam_stable_version_from_json "$tmp" 2>/dev/null || true)
  case "$latest" in ""|*[!A-Za-z0-9._-]*) latest="" ;; *) status="ok" ;; esac
  printf '%s\t%s\t%s\n' "$now" "$status" "$latest" > "$UPDATE_CACHE_FILE.tmp" &&
    mv -f "$UPDATE_CACHE_FILE.tmp" "$UPDATE_CACHE_FILE"
  rm -f -- "$tmp"
  [ "$status" = "ok" ]
}

runtime_probe_url() {
  local url="$1" out="$2"
  : > "$out" || return 1
  runtime_prepare_downloader || return 1
  "$RUNTIME_CURL" -fsSL --connect-timeout 3 --max-time 5 --range 0-3 "$url" 2>/dev/null | head -c 4 > "$out"
  runtime_has_magic "$out"
}

runtime_fetch_url() {
  local url="$1" out="$2" resume="${3:-0}" fetch_pid monitor_pid rc actual
  runtime_prepare_downloader || return 1
  if [ "$resume" = "1" ]; then
    "$RUNTIME_CURL" -fsSL --connect-timeout 8 --retry 2 --retry-delay 1 -C - -o "$out" "$url" &
  else
    "$RUNTIME_CURL" -fsSL --connect-timeout 8 --retry 2 --retry-delay 1 -o "$out" "$url" &
  fi
  fetch_pid=$!
  (
    local now last_time last_size current delta elapsed
    last_time=$(date +%s); last_size=$(runtime_file_size "$out")
    while kill -0 "$fetch_pid" 2>/dev/null; do
      sleep 1
      now=$(date +%s); current=$(runtime_file_size "$out")
      elapsed=$((now - last_time)); delta=$((current - last_size))
      [ "$elapsed" -gt 0 ] || elapsed=1
      [ "$delta" -ge 0 ] || delta=0
      runtime_progress_write downloading "$((RUNTIME_PROGRESS_SOURCE_BASE + current))" "$((delta / elapsed))" "$RUNTIME_PROGRESS_DETAIL"
      last_time=$now; last_size=$current
    done
  ) &
  monitor_pid=$!
  rc=0; wait "$fetch_pid" || rc=$?
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  actual=$(runtime_file_size "$out")
  runtime_progress_write downloading "$((RUNTIME_PROGRESS_SOURCE_BASE + actual))" 0 "$RUNTIME_PROGRESS_DETAIL"
  return "$rc"
}

runtime_file_size() {
  [ -f "$1" ] || { echo 0; return; }
  wc -c < "$1" | tr -d '[:space:]'
}

runtime_probe_batch_results() {
  local root="$1" first="$2" last="$3" candidates="$4" winner id line
  [ -s "$root/winner" ] || return 1
  winner=$(cat "$root/winner")
  [ -e "$root/ok.$winner" ] || return 1
  line=$(sed -n "${winner}p" <<< "$candidates")
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
  id=$first
  while [ "$id" -le "$last" ]; do
    if [ "$id" != "$winner" ] && [ -e "$root/ok.$id" ]; then
      line=$(sed -n "${id}p" <<< "$candidates")
      [ -z "$line" ] || printf '%s\n' "$line"
    fi
    id=$((id + 1))
  done
}

runtime_select_proxy() {
  local sample="$1" probe_root candidates format name base url selected_format selected_base id=0 batch_start=1 batch_count=0
  local batch_size=5 verified=""
  runtime_valid_source "$sample" || return 1
  runtime_prepare_downloader || return 1
  probe_root="$CONFDIR/proxy-probe.$$"
  rm -rf "$probe_root"; mkdir -p "$probe_root" || return 1
  candidates=$(runtime_proxy_candidates)
  while IFS=$'\t' read -r format name base; do
    [ -n "$format" ] && [ -n "$name" ] || continue
    id=$((id + 1))
    batch_count=$((batch_count + 1))
    (
      url=$(runtime_url "$format" "$base" "$sample") || exit 1
      if runtime_probe_url "$url" "$probe_root/probe.$id"; then
        : > "$probe_root/ok.$id"
        if mkdir "$probe_root/winner.lock" 2>/dev/null; then
          printf '%s\n' "$id" > "$probe_root/winner"
        fi
      fi
    ) &
    if [ "$batch_count" -ge "$batch_size" ]; then
      runtime_progress_write probing "$RUNTIME_PROGRESS_DONE_BYTES" 0 "Checking connection"
      wait
      verified=$(runtime_probe_batch_results "$probe_root" "$batch_start" "$id" "$candidates" 2>/dev/null || true)
      [ -z "$verified" ] || break
      rm -rf "$probe_root/winner.lock"; rm -f "$probe_root/winner"
      batch_start=$((id + 1)); batch_count=0
    fi
  done <<< "$candidates"

  if [ -z "$verified" ] && [ "$batch_count" -gt 0 ]; then
    runtime_progress_write probing "$RUNTIME_PROGRESS_DONE_BYTES" 0 "Checking connection"
    wait
    verified=$(runtime_probe_batch_results "$probe_root" "$batch_start" "$id" "$candidates" 2>/dev/null || true)
  fi

  if [ -n "$verified" ]; then
    RUNTIME_VERIFIED_PROXIES="$verified"$'\ndirect\torigin\t'
  elif runtime_probe_url "$(runtime_url direct "" "$sample")" "$probe_root/direct"; then
    RUNTIME_VERIFIED_PROXIES=$'direct\torigin\t'
  else
    rm -rf "$probe_root"
    return 1
  fi
  IFS=$'\t' read -r selected_format RUNTIME_PROXY_NAME selected_base <<< "$RUNTIME_VERIFIED_PROXIES"
  echo "$LOG_PREFIX Runtime connection ready"
  runtime_progress_write connected "$RUNTIME_PROGRESS_DONE_BYTES" 0 "Connection ready"
  rm -rf "$probe_root"
  RUNTIME_PROXY_READY=1
}

# PortMaster core repair uses the same bounded proxy pool as Runtime repair,
# but release assets are ordinary files rather than squashfs images. The
# selected route is never written to progress.tsv, so the UI only exposes a
# connection phase and useful transfer metrics.
pm_release_url() {
  local format="$1" base="$2" asset="$3" direct="$PAM_RELEASE_BASE/$asset"
  case "$asset" in PortMaster.zip|Install.sh|version.json|SHA256SUMS) ;; *) return 1 ;; esac
  case "$format" in
    direct) printf '%s\n' "$direct" ;;
    github|full) printf '%s/%s\n' "${base%/}" "$direct" ;;
    custom) printf '%s/jenny92-tech/PortMaster-GUI/releases/latest/download/%s\n' "${base%/}" "$asset" ;;
    *) return 1 ;;
  esac
}

pm_probe_release_url() {
  local url="$1" out="$2"
  : > "$out" || return 1
  runtime_prepare_downloader || return 1
  "$RUNTIME_CURL" -fsSL --connect-timeout 3 --max-time 5 --range 0-15 "$url" 2>/dev/null |
    head -c 16 > "$out"
  [ -s "$out" ]
}

pm_select_release_routes() {
  local root candidates format name base url id=0 start=1 count=0 verified="" batch_size=5
  runtime_prepare_downloader || return 1
  root="$CONFDIR/pm-probe.$$"
  rm -rf -- "$root"; mkdir -p "$root" || return 1
  candidates=$(runtime_proxy_candidates | awk -F '\t' '$1 != "jsdelivr"')
  while IFS=$'\t' read -r format name base; do
    [ -n "$format" ] && [ -n "$name" ] || continue
    id=$((id + 1)); count=$((count + 1))
    (
      url=$(pm_release_url "$format" "$base" version.json) || exit 1
      if pm_probe_release_url "$url" "$root/probe.$id"; then
        : > "$root/ok.$id"
        if mkdir "$root/winner.lock" 2>/dev/null; then printf '%s\n' "$id" > "$root/winner"; fi
      fi
    ) &
    if [ "$count" -ge "$batch_size" ]; then
      runtime_progress_write probing 3 0 "Checking connection"
      wait
      verified=$(runtime_probe_batch_results "$root" "$start" "$id" "$candidates" 2>/dev/null || true)
      [ -z "$verified" ] || break
      rm -rf -- "$root/winner.lock"; rm -f -- "$root/winner"
      start=$((id + 1)); count=0
    fi
  done <<< "$candidates"
  if [ -z "$verified" ] && [ "$count" -gt 0 ]; then
    runtime_progress_write probing 3 0 "Checking connection"
    wait
    verified=$(runtime_probe_batch_results "$root" "$start" "$id" "$candidates" 2>/dev/null || true)
  fi
  if pm_probe_release_url "$(pm_release_url direct "" version.json)" "$root/direct"; then
    verified+="${verified:+$'\n'}direct"$'\torigin\t'
  fi
  rm -rf -- "$root"
  [ -n "$verified" ] || return 1
  PM_RELEASE_ROUTES="$verified"
  runtime_progress_write connected 5 0 "Connection ready"
}

pm_cancel_requested() { [ -e "$CANCEL_FILE" ]; }

pm_fetch_url() {
  local url="$1" out="$2" start="$3" finish="$4" fetch_pid monitor_pid rc=0
  runtime_prepare_downloader || return 1
  "$RUNTIME_CURL" -fsSL --connect-timeout 8 --retry 2 --retry-delay 1 -C - -o "$out" "$url" 2>/dev/null &
  fetch_pid=$!
  (
    local before now last_time last_size current delta elapsed span percent
    last_time=$(date +%s); last_size=$(runtime_file_size "$out"); before=$last_size
    while kill -0 "$fetch_pid" 2>/dev/null; do
      sleep 1
      if pm_cancel_requested; then kill "$fetch_pid" 2>/dev/null || true; exit 70; fi
      now=$(date +%s); current=$(runtime_file_size "$out")
      elapsed=$((now - last_time)); delta=$((current - last_size)); [ "$elapsed" -gt 0 ] || elapsed=1
      [ "$delta" -ge 0 ] || delta=0
      span=$((finish - start)); percent=$start
      if [ "$current" -gt "$before" ]; then percent=$((start + span / 2)); fi
      runtime_progress_write downloading "$percent" "$((delta / elapsed))" "Downloading verified release assets"
      last_time=$now; last_size=$current
    done
  ) &
  monitor_pid=$!
  wait "$fetch_pid" || rc=$?
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  pm_cancel_requested && return 70
  [ "$rc" = "0" ] || return "$rc"
  runtime_progress_write downloading "$finish" 0 "Downloading verified release assets"
}

pm_download_asset() {
  local asset="$1" out="$2" start="$3" finish="$4" format name base url route_number=0 rc
  while IFS=$'\t' read -r format name base; do
    [ -n "$format" ] && [ -n "$name" ] || continue
    route_number=$((route_number + 1))
    url=$(pm_release_url "$format" "$base" "$asset") || continue
    echo "$LOG_PREFIX release transfer attempt $route_number for $asset"
    if pm_fetch_url "$url" "$out" "$start" "$finish"; then return 0
    else rc=$?; fi
    [ "$rc" != "70" ] || return 70
    echo "$LOG_PREFIX release transfer attempt $route_number failed for $asset"
  done <<< "$PM_RELEASE_ROUTES"
  return 1
}

pm_sha256_file() {
  if [ -x "$PAM_BIN_DIR/sha256sum-portable" ]; then
    "$PAM_BIN_DIR/sha256sum-portable" "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1
  fi
}

pm_checksum_expected() {
  local sums="$1" asset="$2"
  awk -v wanted="$asset" '{ name=$2; sub(/^\*/, "", name); if (name == wanted && $1 ~ /^[0-9A-Fa-f]{64}$/) {print tolower($1); exit} }' "$sums"
}

pm_verify_asset() {
  local sums="$1" asset="$2" path="$3" expected actual
  expected=$(pm_checksum_expected "$sums" "$asset")
  [ -n "$expected" ] || return 1
  actual=$(pm_sha256_file "$path" 2>/dev/null || true)
  actual=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')
  [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

pm_validate_sums() {
  local sums="$1" asset
  [ -s "$sums" ] || return 1
  for asset in version.json Install.sh PortMaster.zip; do
    [ -n "$(pm_checksum_expected "$sums" "$asset")" ] || return 1
  done
}

install_portmaster_release() {
  local cache="$CONFDIR/portmaster-download" sums version installer archive rc installer_device
  sums="$cache/SHA256SUMS"; version="$cache/version.json"
  installer="$cache/Install.sh"; archive="$cache/PortMaster.zip"
  rm -f -- "$CANCEL_FILE"; mkdir -p "$cache" || return 1
  rm -f -- "$sums" "$version" "$installer"
  RUNTIME_PROGRESS_RUNTIME="PortMaster"
  runtime_progress_write preparing 1 0 "Preparing environment repair"
  pm_select_release_routes || { printf 'FAIL\tportmaster\tnetwork\n' >> "$RESULT_FILE"; return 1; }
  pm_download_asset SHA256SUMS "$sums" 5 10 || { rc=$?; printf 'FAIL\tportmaster\t%s\n' "$([ "$rc" = 70 ] && echo cancelled || echo network)" >> "$RESULT_FILE"; return 1; }
  pm_validate_sums "$sums" || { printf 'FAIL\tportmaster\tchecksums\n' >> "$RESULT_FILE"; return 1; }
  pm_download_asset version.json "$version" 10 15 || { printf 'FAIL\tportmaster\tnetwork\n' >> "$RESULT_FILE"; return 1; }
  pm_download_asset Install.sh "$installer" 15 22 || { printf 'FAIL\tportmaster\tnetwork\n' >> "$RESULT_FILE"; return 1; }
  pm_download_asset PortMaster.zip "$archive" 22 78 || { rc=$?; printf 'FAIL\tportmaster\t%s\n' "$([ "$rc" = 70 ] && echo cancelled || echo network)" >> "$RESULT_FILE"; return 1; }
  runtime_progress_write verifying 82 0 "Verifying release assets"
  pm_verify_asset "$sums" version.json "$version" &&
    pm_verify_asset "$sums" Install.sh "$installer" || {
      printf 'FAIL\tportmaster\tchecksum\n' >> "$RESULT_FILE"; return 1;
    }
  if ! pm_verify_asset "$sums" PortMaster.zip "$archive"; then
    echo "$LOG_PREFIX cached PortMaster archive did not match the current stable release; restarting"
    rm -f -- "$archive"
    pm_download_asset PortMaster.zip "$archive" 22 78 && pm_verify_asset "$sums" PortMaster.zip "$archive" || {
      rm -f -- "$archive"
      printf 'FAIL\tportmaster\tchecksum\n' >> "$RESULT_FILE"; return 1;
    }
  fi
  [ -x "$PAM_BIN_DIR/unzip-portable" ] || { printf 'FAIL\tportmaster\tunzip\n' >> "$RESULT_FILE"; return 1; }
  "$PAM_BIN_DIR/unzip-portable" -t "$archive" >/dev/null 2>&1 || {
    printf 'FAIL\tportmaster\tarchive\n' >> "$RESULT_FILE"; return 1;
  }
  pm_cancel_requested && { printf 'FAIL\tportmaster\tcancelled\n' >> "$RESULT_FILE"; return 1; }
  chmod 0700 "$installer" || return 1
  runtime_progress_write installing 88 0 "Installing managed PortMaster core"
  case "$PAM_DEVICE_CLASS" in
    tested) installer_device="${param_device:-auto}" ;;
    official-untested|unsupported-known) installer_device="$PAM_DEVICE_CLASS" ;;
    *) installer_device="auto" ;;
  esac
  PAM_CANCEL_FILE="$CANCEL_FILE" PAM_UNZIP="$PAM_BIN_DIR/unzip-portable" \
    PAM_SHA256="$PAM_BIN_DIR/sha256sum-portable" \
    bash "$installer" --archive "$archive" --target "$PAM_PORTMASTER_DIR" \
      --scripts "$SCRIPTS_DIR" --state-dir "$CONFDIR" --device "$installer_device" || {
        rc=$?; printf 'FAIL\tportmaster\tinstaller-%s\n' "$rc" >> "$RESULT_FILE"; return 1;
      }
  [ -s "$CONFDIR/pending-install.tsv" ] && [ -s "$CONFDIR/pending-manifest.tsv" ] || {
    printf 'FAIL\tportmaster\tpending-validation\n' >> "$RESULT_FILE"; return 1;
  }
  runtime_progress_write complete 100 0 "Installation complete; reopen required"
  printf 'OK\tportmaster\tpending-validation\n' >> "$RESULT_FILE"
}

runtime_download_source() {
  local source="$1" expected="$2" out="$3" format name base url actual rc
  case "$expected" in ""|*[!0-9]*|0) return 1 ;; esac
  if [ -L "$out" ]; then rm -f -- "$out" || return 1; fi
  actual=$(runtime_file_size "$out")
  if [ "$actual" = "$expected" ]; then
    echo "$LOG_PREFIX using complete Runtime cache: $source"
    [ -n "${RUNTIME_DOWNLOAD_VIA:-}" ] || RUNTIME_DOWNLOAD_VIA="Cache"
    runtime_progress_write downloading "$((RUNTIME_PROGRESS_SOURCE_BASE + expected))" 0 "Using local cache"
    return 0
  fi
  if [ "$actual" -gt "$expected" ]; then
    echo "$LOG_PREFIX discarding oversized Runtime cache: $source"
    rm -f -- "$out" || return 1
    actual=0
  elif [ "$actual" -gt 0 ]; then
    echo "$LOG_PREFIX resuming $source from $actual of $expected bytes"
  fi

  while IFS=$'\t' read -r format name base; do
    [ -n "$format" ] && [ -n "$name" ] || continue
    url=$(runtime_url "$format" "$base" "$source") || continue
    echo "$LOG_PREFIX downloading Runtime payload"
    RUNTIME_PROGRESS_DETAIL="Connection ready"
    actual=$(runtime_file_size "$out")
    rc=0
    if [ "$actual" -gt 0 ]; then
      runtime_fetch_url "$url" "$out" 1 || rc=$?
    else
      runtime_fetch_url "$url" "$out" 0 || rc=$?
    fi
    actual=$(runtime_file_size "$out")
    if [ "$rc" = "0" ] && [ "$actual" = "$expected" ]; then
      RUNTIME_DOWNLOAD_VIA="network"
      return 0
    fi
    if [ "$actual" -gt "$expected" ]; then
      rm -f -- "$out"
      actual=0
    fi
    # curl 33 means the endpoint rejected the requested resume offset. Retry
    # that same source cleanly once; exact size validation still gates success.
    if [ "$rc" = "33" ]; then
      echo "$LOG_PREFIX source cannot resume; restarting $source"
      rm -f -- "$out" || return 1
      rc=0
      runtime_fetch_url "$url" "$out" 0 || rc=$?
      actual=$(runtime_file_size "$out")
      if [ "$rc" = "0" ] && [ "$actual" = "$expected" ]; then
        RUNTIME_DOWNLOAD_VIA="network"
        return 0
      fi
      [ "$actual" -le "$expected" ] || rm -f -- "$out"
    fi
  done <<< "$RUNTIME_VERIFIED_PROXIES"
  return 1
}

install_runtime() {
  local runtime="$1" sources source_sizes expected_size actual_size work combined part source source_size target staged cache_root cache_ref cache_dir index runtime_part_done=0
  local RUNTIME_DOWNLOAD_VIA=""
  case "$runtime" in
    ""|*[!A-Za-z0-9._+-]*|.*|*..*)
      printf 'FAIL\truntime\t%s\tinvalid-name\n' "$runtime" >> "$RESULT_FILE"
      return 1
      ;;
  esac
  target="$LIBS_DIR/$runtime.squashfs"
  if [ -d "$target" ] && [ ! -L "$target" ]; then
    printf 'FAIL\truntime\t%s\tinvalid-target\n' "$runtime" >> "$RESULT_FILE"
    return 1
  fi
  sources=$(runtime_sources "$runtime")
  source_sizes=$(runtime_source_sizes "$runtime")
  expected_size=$(runtime_expected_size "$runtime")
  if [ -z "$sources" ] || [ -z "$source_sizes" ] || [ -z "$expected_size" ]; then
    printf 'FAIL\truntime\t%s\tunsupported\n' "$runtime" >> "$RESULT_FILE"
    return 1
  fi
  runtime_progress_write preparing "$RUNTIME_PROGRESS_DONE_BYTES" 0 "$runtime"
  cache_root="$CONFDIR/runtime-cache"
  cache_ref="$cache_root/$RUNTIME_SOURCE_REF"
  cache_dir="$cache_ref/$runtime"
  if [ -L "$cache_root" ] || [ -L "$cache_ref" ] || [ -L "$cache_dir" ]; then
    printf 'FAIL\truntime\t%s\tcache-dir\n' "$runtime" >> "$RESULT_FILE"
    return 1
  fi
  mkdir -p "$cache_dir" || {
    printf 'FAIL\truntime\t%s\tcache-dir\n' "$runtime" >> "$RESULT_FILE"
    return 1
  }
  work="$CONFDIR/runtime-assembly.$$.$runtime"
  combined="$work/$runtime.squashfs"
  rm -rf "$work"; mkdir -p "$work" || {
    printf 'FAIL\truntime\t%s\ttemp-dir\n' "$runtime" >> "$RESULT_FILE"
    return 1
  }
  if ! : > "$combined"; then
    printf 'FAIL\truntime\t%s\ttemp-file\n' "$runtime" >> "$RESULT_FILE"
    rm -rf "$work"; return 1
  fi
  IFS=',' read -r -a runtime_parts <<< "$sources"
  IFS=',' read -r -a runtime_part_sizes <<< "$source_sizes"
  if [ "${#runtime_parts[@]}" != "${#runtime_part_sizes[@]}" ]; then
    printf 'FAIL\truntime\t%s\tcatalog\n' "$runtime" >> "$RESULT_FILE"
    rm -rf "$work"; return 1
  fi
  for index in "${!runtime_parts[@]}"; do
    source="${runtime_parts[$index]}"
    source_size="${runtime_part_sizes[$index]}"
    if ! runtime_valid_source "$source"; then
      printf 'FAIL\truntime\t%s\tcatalog\n' "$runtime" >> "$RESULT_FILE"
      rm -rf "$work"; return 1
    fi
    case "$source_size" in ""|*[!0-9]*|0)
      printf 'FAIL\truntime\t%s\tcatalog\n' "$runtime" >> "$RESULT_FILE"
      rm -rf "$work"; return 1 ;;
    esac
    part="$cache_dir/$source.download"
    RUNTIME_PROGRESS_SOURCE_BASE=$((RUNTIME_PROGRESS_DONE_BYTES + runtime_part_done))
    if [ -L "$part" ]; then
      rm -f -- "$part" || {
        printf 'FAIL\truntime\t%s\tcache-file\n' "$runtime" >> "$RESULT_FILE"
        rm -rf "$work"; return 1
      }
    fi
    if [ "$(runtime_file_size "$part")" != "$source_size" ] &&
       [ "${RUNTIME_PROXY_READY:-0}" != "1" ] && ! runtime_select_proxy "$source"; then
      printf 'FAIL\truntime\t%s\tno-source\n' "$runtime" >> "$RESULT_FILE"
      rm -rf "$work"; return 1
    fi
    if ! runtime_download_source "$source" "$source_size" "$part" || ! cat "$part" >> "$combined"; then
      printf 'FAIL\truntime\t%s\tdownload\n' "$runtime" >> "$RESULT_FILE"
      rm -rf "$work"; return 1
    fi
    runtime_part_done=$((runtime_part_done + source_size))
    runtime_progress_write assembling "$((RUNTIME_PROGRESS_DONE_BYTES + runtime_part_done))" 0 "$source"
  done
  runtime_progress_write verifying "$((RUNTIME_PROGRESS_DONE_BYTES + expected_size))" 0 "$runtime"
  if ! runtime_has_magic "$combined"; then
    printf 'FAIL\truntime\t%s\tinvalid-image\n' "$runtime" >> "$RESULT_FILE"
    rm -rf "$cache_dir" "$work"; return 1
  fi
  actual_size=$(wc -c < "$combined" | tr -d '[:space:]')
  if [ "$actual_size" != "$expected_size" ]; then
    printf 'FAIL\truntime\t%s\tsize-mismatch\n' "$runtime" >> "$RESULT_FILE"
    echo "$LOG_PREFIX Runtime size mismatch: $runtime expected=$expected_size actual=$actual_size"
    rm -rf "$cache_dir" "$work"; return 1
  fi

  staged="$LIBS_DIR/.pam-$runtime.squashfs.$$"
  runtime_progress_write installing "$((RUNTIME_PROGRESS_DONE_BYTES + expected_size))" 0 "$target"
  if $ESUDO mkdir -p "$LIBS_DIR" &&
     $ESUDO mv -- "$combined" "$staged" &&
     $ESUDO chmod 0644 "$staged" &&
     $ESUDO mv -f -- "$staged" "$target"; then
    printf 'OK\truntime\t%s\t%s\n' "$runtime" "${RUNTIME_DOWNLOAD_VIA:-$RUNTIME_PROXY_NAME}" >> "$RESULT_FILE"
    echo "$LOG_PREFIX Runtime installed: $runtime"
    rm -rf "$cache_dir"
    rm -rf "$work"
    return 0
  fi
  $ESUDO rm -f -- "$staged" 2>/dev/null || true
  printf 'FAIL\truntime\t%s\tinstall\n' "$runtime" >> "$RESULT_FILE"
  rm -rf "$work"
  return 1
}

apply_plan() {
  local stamp kind arg dest base bucket batch item trash_failed=0 empty_failed=0 runtime_bytes
  local device_risk_ack=0 device_support_ack=0
  stamp=$(date +%Y%m%d-%H%M%S)
  : > "$RESULT_FILE"
  rm -f -- "$PROGRESS_FILE" "$PROGRESS_FILE.tmp.$$"
  if [ ! -f "$PLAN_FILE" ]; then
    printf 'FAIL\toperation\n' >> "$RESULT_FILE"
    return
  fi
  runtime_progress_prepare_plan

  while IFS=$'\t' read -r kind arg; do
    case "$kind" in
      \#*|"") continue ;;

      TRASH|DELETE_MANAGED)
        # UI 只能处理三个受管根目录的直接子项。即使 plan.txt 损坏，也不能让提权的
        # shell 移动或删除任意路径；本 APP、PortMaster 和临时 .port.sh 再额外挡一次。
        base=$(basename "$arg")
        if ! { [ "$(dirname "$arg")" = "$SCRIPTS_DIR" ] && [[ "$base" = *.sh ]] ||
               { [ -n "$IMAGES_DIR" ] && [ "$(dirname "$arg")" = "$IMAGES_DIR" ]; } ||
               [ "$(dirname "$arg")" = "$GAMEDIRS_DIR" ]; } ||
           [ "$arg" = "$GAMEDIR" ] ||
           [ "$arg" = "$PAM_DIR/$(basename "$0")" ] ||
           [ "$base" = "APP Manager.sh" ] ||
           [ "$base" = "PortMaster" ] || [ "$base" = "PortMaster.sh" ] ||
           [ "$base" = ".port.sh" ]; then
          printf 'FAIL\toperation\n' >> "$RESULT_FILE"
          echo "$LOG_PREFIX rejected trash path: $arg"
          trash_failed=1
          continue
        fi
        if [ ! -e "$arg" ] && [ ! -L "$arg" ]; then
          echo "$LOG_PREFIX already removed: $base"
          continue
        fi
        if [ "$(dirname "$arg")" = "$GAMEDIRS_DIR" ] && [ "$trash_failed" = "1" ]; then
          echo "$LOG_PREFIX kept game folder after earlier move failure: $base"
          continue
        fi
        if [ "$kind" = "DELETE_MANAGED" ]; then
          if $ESUDO rm -rf -- "$arg"; then
            echo "$LOG_PREFIX permanently deleted managed item: $base"
          else
            printf 'FAIL\tdelete\t%s\n' "$base" >> "$RESULT_FILE"
            trash_failed=1
          fi
          continue
        fi
        # MiniLoong 的 SH 根和 Data 根是同一目录，不能只看父目录分类。
        # 只有 .sh 文件是启动项；其余目录/文件都按 Data 保存来源。
        if [[ "$base" = *.sh ]] && [ "$(dirname "$arg")" = "$SCRIPTS_DIR" ]; then bucket="scripts"
        elif [ -n "$IMAGES_DIR" ] && [ "$(dirname "$arg")" = "$IMAGES_DIR" ]; then bucket="images"
        else bucket="data"
        fi
        # 保留来源类型，恢复时才能精确放回 SH / 图片 / Data 原根目录。
        dest="$TRASH_DIR/$stamp/$bucket"
        $ESUDO mkdir -p "$dest"
        # 同来源根下理论上不会重名；仍保留防御，绝不覆盖回收站内容。
        if [ -e "$dest/$base" ]; then
          n=2
          while [ -e "$dest/$base.$n" ]; do n=$((n + 1)); done
          base="$base.$n"
        fi
        if $ESUDO mv -- "$arg" "$dest/$base"; then
          echo "$LOG_PREFIX moved to trash: $base"
        else
          printf 'FAIL\ttrash\t%s\n' "$base" >> "$RESULT_FILE"
          trash_failed=1
          $ESUDO rmdir -- "$dest" "$TRASH_DIR/$stamp" 2>/dev/null || true
        fi
        ;;

      EMPTY_TRASH)
        empty_failed=0
        # 普通 * 不包含隐藏项；三组 glob 才能完整覆盖，并且始终限定在 APP 回收站内。
        for item in "$TRASH_DIR"/* "$TRASH_DIR"/.[!.]* "$TRASH_DIR"/..?*; do
          [ -e "$item" ] || [ -L "$item" ] || continue
          $ESUDO rm -rf -- "$item" || empty_failed=1
        done
        if [ "$empty_failed" = "1" ]; then
          printf 'FAIL\tempty_trash\n' >> "$RESULT_FILE"
        else
          echo "$LOG_PREFIX trash emptied"
        fi
        ;;

      RESTORE_TRASH)
        # 新格式按来源分类，可精确恢复。旧版扁平批次则用安全可推导的
        # 类型兼容：.sh 回 SH 目录，目录回 Data，其余文件回图片目录。
        for batch in "$TRASH_DIR"/* "$TRASH_DIR"/.[!.]* "$TRASH_DIR"/..?*; do
          [ -d "$batch" ] || continue
          if [ -L "$batch" ]; then
            printf 'FAIL\trestore\t%s\n' "$(basename "$batch")" >> "$RESULT_FILE"
            continue
          fi
          restore_bucket "$batch/scripts" "$SCRIPTS_DIR" scripts
          restore_bucket "$batch/images" "$IMAGES_DIR" images
          restore_bucket "$batch/data" "$GAMEDIRS_DIR" data
          for item in "$batch"/* "$batch"/.[!.]* "$batch"/..?*; do
            [ -e "$item" ] || [ -L "$item" ] || continue
            base=$(basename "$item")
            case "$base" in scripts|images|data) [ -d "$item" ] && continue ;; esac
            if [ -d "$item" ]; then
              restore_one "$item" "$GAMEDIRS_DIR" data
            elif [[ "$base" = *.sh ]]; then
              restore_one "$item" "$SCRIPTS_DIR" scripts
            else
              restore_one "$item" "$IMAGES_DIR" images
            fi
          done
          $ESUDO rmdir -- "$batch" 2>/dev/null || true
        done
        echo "$LOG_PREFIX trash restore completed"
        ;;

      RESTORE_ITEM)
        restore_selected_item "$arg"
        ;;

      DELETE_ITEM)
        delete_selected_item "$arg"
        ;;

      INSTALL_RUNTIME)
        RUNTIME_PROGRESS_INDEX=$((RUNTIME_PROGRESS_INDEX + 1))
        RUNTIME_PROGRESS_RUNTIME="$arg"
        runtime_progress_write preparing "$RUNTIME_PROGRESS_DONE_BYTES" 0 "$arg"
        runtime_bytes=$(runtime_expected_size "$arg")
        case "$runtime_bytes" in ""|*[!0-9]*) runtime_bytes=0 ;; esac
        if install_runtime "$arg"; then
          RUNTIME_PROGRESS_DONE_BYTES=$((RUNTIME_PROGRESS_DONE_BYTES + runtime_bytes))
          runtime_progress_write finished "$RUNTIME_PROGRESS_DONE_BYTES" 0 "$arg"
        else
          RUNTIME_PROGRESS_DONE_BYTES=$((RUNTIME_PROGRESS_DONE_BYTES + runtime_bytes))
          runtime_progress_write failed "$RUNTIME_PROGRESS_DONE_BYTES" 0 "$arg"
        fi
        ;;

      INSTALL_PORTMASTER)
        if [ "$arg" != "stable" ]; then
          printf 'FAIL\tportmaster\tinvalid-release\n' >> "$RESULT_FILE"
        elif [ "$PAM_TARGET_CONFIRMED" != "1" ] || [ -z "$PAM_PORTMASTER_DIR" ]; then
          printf 'FAIL\tportmaster\tunknown-target\n' >> "$RESULT_FILE"
        elif [ "$PAM_DEVICE_CLASS" = "official-untested" ] && [ "$device_risk_ack" != "1" ]; then
          printf 'FAIL\tportmaster\tdevice-ack-required\n' >> "$RESULT_FILE"
        elif [ "$PAM_DEVICE_CLASS" = "unsupported-known" ] &&
             { [ "$device_risk_ack" != "1" ] || [ "$device_support_ack" != "1" ]; }; then
          printf 'FAIL\tportmaster\tdevice-acks-required\n' >> "$RESULT_FILE"
        elif [ "$PAM_DEVICE_CLASS" != "tested" ] && [ "$PAM_DEVICE_CLASS" != "official-untested" ] &&
             [ "$PAM_DEVICE_CLASS" != "unsupported-known" ]; then
          printf 'FAIL\tportmaster\tunsupported-device\n' >> "$RESULT_FILE"
        elif ! install_portmaster_release; then
          if grep -q $'FAIL\tportmaster\tcancelled' "$RESULT_FILE" 2>/dev/null; then
            runtime_progress_write cancelled 100 0 "Environment repair cancelled before installation"
          else
            runtime_progress_write failed 100 0 "PortMaster environment repair failed"
          fi
        fi
        ;;

      ACK_DEVICE_RISK)
        if [ "$arg" = "$PAM_DEVICE_CLASS" ] &&
           { [ "$arg" = "official-untested" ] || [ "$arg" = "unsupported-known" ]; }; then
          device_risk_ack=1
        else
          printf 'FAIL\tportmaster\tinvalid-device-ack\n' >> "$RESULT_FILE"
        fi
        ;;

      ACK_DEVICE_SUPPORT)
        if [ "$PAM_DEVICE_CLASS" = "unsupported-known" ] && [ "$arg" = "$PAM_PORTMASTER_DIR" ]; then
          device_support_ack=1
        else
          printf 'FAIL\tportmaster\tinvalid-support-ack\n' >> "$RESULT_FILE"
        fi
        ;;

      *)
        printf 'FAIL\toperation\n' >> "$RESULT_FILE"
        echo "$LOG_PREFIX unknown action: $kind"
        ;;
    esac
  done < "$PLAN_FILE"

  if [ "$RUNTIME_PROGRESS_COUNT" -gt 0 ] && [ "$PORTMASTER_PROGRESS" != "1" ]; then
    runtime_progress_write complete "$RUNTIME_PROGRESS_DONE_BYTES" 0 "Runtime repair complete"
  fi

  sync
}

pending_value() {
  local key="$1" file="$CONFDIR/pending-install.tsv"
  awk -F '\t' -v key="$key" '$1 == key {sub(/^[^\t]*\t/, ""); print; exit}' "$file"
}

validation_write() {
  local status="$1" detail="$2" tmp="$VALIDATION_RESULT_FILE.tmp.$$"
  detail=${detail//$'\t'/ }; detail=${detail//$'\r'/ }; detail=${detail//$'\n'/ }
  printf '1\t%s\t%s\n' "$status" "$detail" > "$tmp" && mv -f -- "$tmp" "$VALIDATION_RESULT_FILE"
}

pending_manifest_valid() {
  local manifest="$CONFDIR/pending-manifest.tsv" hash relative actual
  [ -s "$manifest" ] || return 1
  while IFS=$'\t' read -r hash relative; do
    case "$hash" in ""|*[!0-9A-Fa-f]*) return 1 ;; esac
    [ "${#hash}" = 64 ] || return 1
    case "$relative" in ""|/*|../*|*/../*|*/..) return 1 ;; esac
    [ -f "$PAM_PORTMASTER_DIR/$relative" ] || return 1
    actual=$(pm_sha256_file "$PAM_PORTMASTER_DIR/$relative" 2>/dev/null || true)
    [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = \
      "$(printf '%s' "$hash" | tr '[:upper:]' '[:lower:]')" ] || return 1
  done < "$manifest"
}

pending_core_valid() {
  local expected_target expected_scripts expected_device version
  expected_target=$(pending_value target); expected_scripts=$(pending_value scripts)
  expected_device=$(pending_value device)
  [ -n "$expected_target" ] && [ "$expected_target" = "$PAM_PORTMASTER_DIR" ] || return 1
  [ -n "$expected_scripts" ] && [ "$expected_scripts" = "$SCRIPTS_DIR" ] || return 1
  case "$expected_device" in miniloong|trimui|unknown|official-untested|unsupported|unsupported-known) ;; *) return 1 ;; esac
  case "$expected_device" in
    miniloong) [ "$param_device" = "miniloong" ] || return 1 ;;
    trimui) [ "$param_device" = "trimui" ] || return 1 ;;
    official-untested) [ "$PAM_DEVICE_CLASS" = "official-untested" ] || return 1 ;;
    unsupported|unsupported-known) [ "$PAM_DEVICE_CLASS" = "unsupported-known" ] || return 1 ;;
    unknown) [ "$PAM_DEVICE_CLASS" = "unsupported-known" ] || return 1 ;;
  esac
  [ "$(pam_core_health)" = "healthy" ] || return 1
  version=$(pam_core_version); [ -n "$version" ] || return 1
  [ -f "$PAM_PORTMASTER_DIR/pugwash" ] || [ -f "$PAM_PORTMASTER_DIR/harbourmaster" ] || return 1
  pending_manifest_valid
}

remove_pending_core() {
  local relative top seen="$CONFDIR/.validation-tops.$$"
  : > "$seen" || return 1
  while IFS=$'\t' read -r _ relative; do
    case "$relative" in ""|/*|../*|*/../*|*/..) continue ;; esac
    top=${relative%%/*}
    case "$top" in ""|libs|config|themes|logs|cache|.appmanager-state) continue ;; esac
    grep -Fqx "$top" "$seen" 2>/dev/null || printf '%s\n' "$top" >> "$seen"
  done < "$CONFDIR/pending-manifest.tsv"
  while IFS= read -r top; do rm -rf -- "$PAM_PORTMASTER_DIR/$top" || true; done < "$seen"
  rm -f -- "$seen" "$SCRIPTS_DIR/PortMaster.sh"
}

rollback_pending_core() {
  local mode item restored=0
  mode=$(pending_value mode)
  remove_pending_core
  if [ "$mode" = "update" ]; then
    [ -d "$CONFDIR/rollback/core" ] || {
      rm -rf -- "$CONFDIR/rollback"
      rm -f -- "$CONFDIR/pending-install.tsv" "$CONFDIR/pending-manifest.tsv"
      return 1
    }
    for item in "$CONFDIR/rollback/core"/* "$CONFDIR/rollback/core"/.[!.]* "$CONFDIR/rollback/core"/..?*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      mv -- "$item" "$PAM_PORTMASTER_DIR/" || return 1
    done
    if [ -f "$CONFDIR/rollback/PortMaster.sh" ]; then
      mv -f -- "$CONFDIR/rollback/PortMaster.sh" "$SCRIPTS_DIR/PortMaster.sh" || return 1
    fi
    restored=1
  fi
  rm -rf -- "$CONFDIR/rollback"
  rm -f -- "$CONFDIR/pending-install.tsv" "$CONFDIR/pending-manifest.tsv"
  [ "$restored" = "1" ]
}

validate_pending_install() {
  local mode
  [ -s "$CONFDIR/pending-install.tsv" ] || { validation_write none "No pending installation"; return 0; }
  validation_write checking "Validating installed PortMaster core"
  if [ "${PAM_TEST_INTERRUPT_VALIDATION:-0}" = "1" ]; then
    validation_write interrupted "Validation was interrupted before any state changed"
    return 75
  fi
  if pending_core_valid; then
    rm -rf -- "$CONFDIR/rollback"
    rm -f -- "$CONFDIR/pending-install.tsv" "$CONFDIR/pending-manifest.tsv"
    validation_write valid "PortMaster environment validated"
    return 0
  fi
  mode=$(pending_value mode)
  if rollback_pending_core; then
    validation_write restored "The previous PortMaster environment was restored"
  else
    validation_write no-usable "The incomplete first installation was removed"
  fi
  echo "$LOG_PREFIX pending PortMaster validation failed (mode=$mode)"
  return 1
}

# ── 主入口 ────────────────────────────────────────────────────────────
# 容量统计会递归读整个游戏目录，绝不能放在 LÖVE 渲染线程。
# UI 用 --scan-sizes 后台启动这一模式；这里原子替换缓存，UI 始终可以
# 先读上一份完整结果。du 统计占用的磁盘块，比逻辑文件长度更接近真实
# 可释放空间。
size_one() {
  local path="$1" kb
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if command -v nice >/dev/null 2>&1; then
    kb=$(nice -n 19 du -sk "$path" 2>/dev/null | awk 'NR == 1 {print $1}')
  else
    kb=$(du -sk "$path" 2>/dev/null | awk 'NR == 1 {print $1}')
  fi
  case "$kb" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\t%s\n' "$((kb * 1024))" "$path" >> "$SIZE_TMP"
}

scan_sizes() {
  local path batch bucket item structured
  SIZE_TMP="${SIZE_FILE}.tmp.$$"
  : > "$SIZE_TMP" || return 1

  # 首页与残留页使用的 Data 目录。APP Manager 自身另行统计
  # trash 的直接项，不把 runtime 等自身文件算进可卸载内容。
  for path in "$GAMEDIRS_DIR"/*; do
    [ -e "$path" ] || continue
    [ "$path" = "$GAMEDIR" ] && continue
    size_one "$path"
  done

  # SH 和图片都是直接文件，同样记录后才能精确合并一个 Item。
  for path in "$SCRIPTS_DIR"/*.sh; do
    [ -f "$path" ] || continue
    size_one "$path"
  done
  if [ -n "$IMAGES_DIR" ]; then
    for path in "$IMAGES_DIR"/*; do
      [ -f "$path" ] || continue
      size_one "$path"
    done
  fi

  # 回收站 UI 展示的是 batch 下各类型的直接项，缓存也保持同样
  # 粒度，才能对单个条目和彻底删除选中正确求和。
  for batch in "$TRASH_DIR"/* "$TRASH_DIR"/.[!.]* "$TRASH_DIR"/..?*; do
    [ -e "$batch" ] || [ -L "$batch" ] || continue
    if [ ! -d "$batch" ] || [ -L "$batch" ]; then
      size_one "$batch"
      continue
    fi
    structured=0
    for bucket in scripts data images; do
      [ -d "$batch/$bucket" ] || continue
      structured=1
      for item in "$batch/$bucket"/* "$batch/$bucket"/.[!.]* "$batch/$bucket"/..?*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        size_one "$item"
      done
    done
    for item in "$batch"/* "$batch"/.[!.]* "$batch"/..?*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      if [ "$structured" = "1" ]; then
        case "$(basename "$item")" in scripts|data|images) continue ;; esac
      fi
      size_one "$item"
    done
  done

  mv -f "$SIZE_TMP" "$SIZE_FILE"
  echo "$LOG_PREFIX size cache updated"
}

if [ "$SIZE_ONLY" = "1" ]; then
  scan_sizes
  exit $?
fi

if [ "$HEALTH_ONLY" = "1" ]; then
  printf '%s\t%s\t%s\t%s\n' "$(pam_core_health)" "$(pam_core_version)" "$PAM_DEVICE_CLASS" "$PAM_PORTMASTER_DIR"
  exit 0
fi

if [ "$CHECK_UPDATE_ONLY" = "1" ]; then
  pam_check_update
  rc=$?
  write_env
  exit "$rc"
fi

if [ "$VALIDATE_ONLY" = "1" ]; then
  validate_pending_install
  rc=$?
  write_env
  exit "$rc"
fi

write_env
if [ "$APPLY_ONLY" = "1" ]; then
  apply_plan
  write_env          # 空间、Runtime 和目录状态都可能变化
  # plan.txt is the UI's completion signal. Remove it only after env.json is
  # fully refreshed, otherwise the renderer can race a partially-written file.
  $ESUDO rm -f "$PLAN_FILE"
  exit 0
fi

if [ "$STATE_DIR" = "$PAM_APP_ROOT/state" ]; then
  export PAM_ENV="$PAM_APP_ROOT/state/env.json"
else
  export PAM_ENV="$CONFDIR/env.json"
fi
export PAM_SOURCE_DIR="$PAM_DIR"
run_portable_ui() {
  local love_pid key_pid=0 exit_code=1
  if [ ! -x "$PAM_APP_ROOT/runtime/love.aarch64" ] || [ ! -f "$PAM_APP_ROOT/love_ui/main.lua" ]; then
    echo "$LOG_PREFIX private LÖVE runtime or UI is missing"
    return 1
  fi
  export LOVE_IDENTITY="port_app_manager"
  export LOVE_WINDOW_TITLE="Port App Manager"
  export LOVE_FONT_PATH SDL_GAMECONTROLLERCONFIG_FILE SSL_CERT_FILE CURL_CA_BUNDLE
  export LIBGL_ES=2 LIBGL_GL=21
  if [ -S "${XDG_RUNTIME_DIR:-/run}/wayland-0" ]; then
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" SDL_VIDEODRIVER=wayland
    unset LIBGL_FB
  else
    unset SDL_VIDEODRIVER WAYLAND_DISPLAY
    export LIBGL_FB=4; [ ! -e /dev/dri/card0 ] && LIBGL_FB=2
  fi
  if [ -x "$PAM_BIN_DIR/gptokeyb" ]; then
    $ESUDO "$PAM_BIN_DIR/gptokeyb" love.aarch64 -c "$PAM_APP_ROOT/love_ui/ui.gptk" &
    key_pid=$!
    pm_platform_helper love.aarch64 2>/dev/null || true
  fi
  cd "$PAM_APP_ROOT/love_ui" || return 1
  env LD_LIBRARY_PATH="$PAM_RUNTIME_DIR/libs.aarch64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$PAM_APP_ROOT/runtime/love.aarch64" "$PAM_APP_ROOT/love_ui" &
  love_pid=$!
  wait "$love_pid"; exit_code=$?
  if [ "$key_pid" != "0" ]; then kill "$key_pid" 2>/dev/null; wait "$key_pid" 2>/dev/null || true; fi
  return "$exit_code"
}

run_portable_ui || true
pm_finish
exit 0
