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
RUNTIME_METADATA_ONLY=0
INSTALL_PLAN_ONLY=0
case "${1:-}" in
  --apply-plan) APPLY_ONLY=1 ;;
  --scan-sizes) SIZE_ONLY=1 ;;
  --health-check) HEALTH_ONLY=1 ;;
  --check-pm-update) CHECK_UPDATE_ONLY=1 ;;
  --check-pm-update-force) CHECK_UPDATE_ONLY=1; FORCE_UPDATE_CHECK=1 ;;
  --validate-pending) VALIDATE_ONLY=1 ;;
  --refresh-runtime-metadata) RUNTIME_METADATA_ONLY=1 ;;
  --write-install-plan) INSTALL_PLAN_ONLY=1 ;;
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
  elif [ -d "/userdata/system/.local/share/PortMaster/" ]; then controlfolder="/userdata/system/.local/share/PortMaster"
  elif [ -d "/mnt/SDCARD/Apps/PortMaster/PortMaster/" ]; then controlfolder="/mnt/SDCARD/Apps/PortMaster/PortMaster"
  elif [ -d "/mnt/mmc/MUOS/PortMaster/" ]; then controlfolder="/mnt/mmc/MUOS/PortMaster"
  elif [ -d "/mnt/sdcard/Roms/.portmaster/PortMaster/" ]; then controlfolder="/mnt/sdcard/Roms/.portmaster/PortMaster"
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
  PAM_RELEASE_CHANNEL="official"
  PAM_GAMEDIRS_DIR_DEFAULT=""
  PAM_FRONTEND_KIND_DEFAULT="script-internal"
  PAM_FRONTEND_DIR_DEFAULT=""
  PAM_FRONTEND_NAMES_DEFAULT="PortMaster.sh"
  PAM_FRONTEND_LAUNCHER_NAME="PortMaster.sh"
  PAM_PYTHON_RUNTIME_FALLBACK="0"
  if [ -f "${PAM_LOONG_VERSION_FILE:-/loong/loong_version}" ]; then
    CFW_NAME="Loong"; PAM_DEVICE_NAME="MiniLoong Pocket One"; PAM_DEVICE_CLASS="tested"
    param_device="miniloong"; DEVICE_ARCH="aarch64"
    directory="${PAM_DIRECTORY_OVERRIDE:-mnt/sdcard/roms}"
    [ -n "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || PAM_PORTMASTER_DIR="/mnt/sdcard/roms/ports/PortMaster"
    PAM_RELEASE_CHANNEL="miniloong-custom"
    PAM_PYTHON_RUNTIME_FALLBACK="1"
    PAM_TARGET_CONFIRMED="1"
    PAM_GAMEDIRS_DIR_DEFAULT="/mnt/sdcard/roms/ports"
    DISPLAY_WIDTH="${DISPLAY_WIDTH:-960}"; DISPLAY_HEIGHT="${DISPLAY_HEIGHT:-720}"
  elif { [ -n "${PAM_TRIMUI_ROOT:-}" ] && [ -d "$PAM_TRIMUI_ROOT" ]; } ||
       [ -d "/usr/trimui" ] ||
       [ "${CFW_NAME:-}" = "TrimUI" ] ||
       { case "$PAM_DIR" in /mnt/SDCARD/Roms/PORTS|/mnt/SDCARD/Roms/PORTS/*) true ;; *) false ;; esac; }; then
    CFW_NAME="TrimUI"; PAM_DEVICE_NAME="TrimUI"; PAM_DEVICE_CLASS="tested"
    param_device="trimui"
    directory="${PAM_DIRECTORY_OVERRIDE:-mnt/SDCARD/Data}"
    [ -n "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || PAM_PORTMASTER_DIR="/mnt/SDCARD/Apps/PortMaster/PortMaster"
    PAM_TARGET_CONFIRMED="1"
    PAM_GAMEDIRS_DIR_DEFAULT="/mnt/SDCARD/Data/ports"
    PAM_FRONTEND_KIND_DEFAULT="trimui"
    PAM_FRONTEND_DIR_DEFAULT="${PAM_PORTMASTER_DIR%/PortMaster}"
    PAM_FRONTEND_NAMES_DEFAULT="launch.sh,config.json,icon.png"
    PAM_FRONTEND_LAUNCHER_NAME="launch.sh"
  elif { [ -n "${PAM_MUOS_ROOT:-}" ] && [ -d "$PAM_MUOS_ROOT" ]; } ||
       [ -d "/mnt/mmc/MUOS" ] || [ "${CFW_NAME:-}" = "muOS" ]; then
    CFW_NAME="muOS"; PAM_DEVICE_NAME="muOS"; PAM_DEVICE_CLASS="official-untested"
    param_device="muos"; DEVICE_ARCH="aarch64"
    [ -n "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || PAM_PORTMASTER_DIR="/mnt/mmc/MUOS/PortMaster"
    PAM_TARGET_CONFIRMED="1"
    case "$PAM_DIR" in
      /mnt/sdcard/*) directory="mnt/sdcard"; PAM_GAMEDIRS_DIR_DEFAULT="/mnt/sdcard/ports" ;;
      *) directory="mnt/mmc"; PAM_GAMEDIRS_DIR_DEFAULT="/mnt/mmc/ports" ;;
    esac
    PAM_FRONTEND_KIND_DEFAULT="control-internal"
    PAM_FRONTEND_DIR_DEFAULT="/roms/ports/PortMaster"
    PAM_FRONTEND_NAMES_DEFAULT="control.txt"
    PAM_FRONTEND_LAUNCHER_NAME="control.txt"
  elif [ -f "${PAM_KNULLI_MARKER:-/userdata/system/knulli.conf}" ] || [ -f "/etc/knulli-version" ]; then
    CFW_NAME="Knulli"; PAM_DEVICE_NAME="Knulli"; PAM_DEVICE_CLASS="official-untested"
    param_device="knulli"; DEVICE_ARCH="aarch64"
    [ -n "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || PAM_PORTMASTER_DIR="/userdata/system/.local/share/PortMaster"
    PAM_TARGET_CONFIRMED="1"; directory="userdata/roms"; PAM_GAMEDIRS_DIR_DEFAULT="/userdata/roms/ports"
    PAM_FRONTEND_KIND_DEFAULT="script-external"
  elif [ -f "${PAM_BATOCERA_VERSION_FILE:-/etc/batocera-version}" ]; then
    CFW_NAME="Batocera"; PAM_DEVICE_NAME="Batocera"; PAM_DEVICE_CLASS="official-untested"
    param_device="batocera"; DEVICE_ARCH="aarch64"
    [ -n "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || PAM_PORTMASTER_DIR="/userdata/system/.local/share/PortMaster"
    PAM_TARGET_CONFIRMED="1"; directory="userdata/roms"; PAM_GAMEDIRS_DIR_DEFAULT="/userdata/roms/ports"
    PAM_FRONTEND_KIND_DEFAULT="script-external"
  elif { [ -n "${PAM_SPRUCE_ROOT:-}" ] && [ -d "$PAM_SPRUCE_ROOT" ]; } || [ -d "/mnt/sdcard/spruce" ]; then
    CFW_NAME="Miyoo"; PAM_DEVICE_NAME="Miyoo / Spruce"; PAM_DEVICE_CLASS="official-untested"
    param_device="miyoo"; DEVICE_ARCH="aarch64"
    [ -n "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || PAM_PORTMASTER_DIR="/mnt/sdcard/Roms/.portmaster/PortMaster"
    PAM_TARGET_CONFIRMED="1"; directory="/mnt/sdcard/Roms/PORTS64/"; PAM_GAMEDIRS_DIR_DEFAULT="/mnt/sdcard/Roms/PORTS64"
    PAM_FRONTEND_KIND_DEFAULT="control-internal"
    PAM_FRONTEND_DIR_DEFAULT="/root/.local/share/PortMaster"
    PAM_FRONTEND_NAMES_DEFAULT="control.txt"
    PAM_FRONTEND_LAUNCHER_NAME="control.txt"
  elif [ -n "$PAM_PORTMASTER_DIR" ] && [ -f "$PAM_PORTMASTER_DIR/control.txt" ]; then
    PAM_DEVICE_NAME="${CFW_NAME:-PortMaster device}"; PAM_DEVICE_CLASS="unsupported-known"
    param_device="generic"
    PAM_TARGET_CONFIRMED="1"
  elif [ -n "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] && [ -n "${PAM_SCRIPTS_DIR_OVERRIDE:-$PAM_DIR}" ]; then
    PAM_DEVICE_NAME="${PAM_DEVICE_NAME_OVERRIDE:-Unverified device}"
    PAM_DEVICE_CLASS="unsupported-known"; param_device="generic"; PAM_TARGET_CONFIRMED="1"
  fi
  [ -z "${PAM_DEVICE_CLASS_OVERRIDE:-}" ] || PAM_DEVICE_CLASS="$PAM_DEVICE_CLASS_OVERRIDE"
  [ -z "${PAM_DEVICE_NAME_OVERRIDE:-}" ] || PAM_DEVICE_NAME="$PAM_DEVICE_NAME_OVERRIDE"
  [ -z "${PAM_TARGET_CONFIRMED_OVERRIDE:-}" ] || PAM_TARGET_CONFIRMED="$PAM_TARGET_CONFIRMED_OVERRIDE"
  if [ "$PAM_TARGET_CONFIRMED" != "1" ]; then PAM_PORTMASTER_DIR=""; fi
}

pam_detect_profile
[ -z "${PAM_PARAM_DEVICE_OVERRIDE:-}" ] || param_device="$PAM_PARAM_DEVICE_OVERRIDE"
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
PAM_FRONTEND_KIND="${PAM_FRONTEND_KIND_DEFAULT:-script-internal}"
PAM_FRONTEND_DIR="${PAM_FRONTEND_DIR_OVERRIDE:-${PAM_FRONTEND_DIR_DEFAULT:-$SCRIPTS_DIR}}"
PAM_FRONTEND_NAMES="${PAM_FRONTEND_NAMES_DEFAULT:-PortMaster.sh}"
PAM_FRONTEND_LAUNCHER="$PAM_FRONTEND_DIR/${PAM_FRONTEND_LAUNCHER_NAME:-PortMaster.sh}"
if [ -z "$directory" ]; then
  case "$PAM_DIR" in
    */Roms/PORTS|*/Roms/Ports) directory="${PAM_DIR%/Roms/*}/Data" ;;
    */ROMS/Ports) directory="${PAM_DIR%/ROMS/Ports}/ports" ;;
    */roms/ports_scripts) directory="${PAM_DIR%/roms/ports_scripts}/roms/ports" ;;
    */ports|*/PORTS|*/Ports) directory="$PAM_DIR" ;;
    *) directory="$PAM_DIR" ;;
  esac
fi
if [ -n "${PAM_GAMEDIRS_DIR_DEFAULT:-}" ] && [ -z "${PAM_DIRECTORY_OVERRIDE:-}" ]; then
  GAMEDIRS_DIR="$PAM_GAMEDIRS_DIR_DEFAULT"
else
  case "$directory" in
    */ports|*/PORTS|*/Ports) GAMEDIRS_DIR="/${directory#/}" ;;
    *) GAMEDIRS_DIR="/${directory#/}/ports" ;;
  esac
fi
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
PORTMASTER_ACTIVE_FILE="$CONFDIR/portmaster-active.tsv"
PORTMASTER_ACTIVE_LOCK="$CONFDIR/portmaster-active.lock"
APPLY_HELPER="$CONFDIR/apply-helper.sh"
SIZE_FILE="$CONFDIR/sizes.tsv"
RUNTIME_METADATA="$CONFDIR/runtime-metadata.tsv"

#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
PORT_SRC="$(cd "$(dirname "$0")" && pwd)"
source "$PORT_SRC/appmanager_sources.sh"
source "$KIT/github_proxy.sh"
#@KIT-END

mkdir -p "$PAM_APP_ROOT" "$CONFDIR" "$TRASH_DIR"
PORTMASTER_ACTIVE=0

# A killed UI must not make an in-flight background repair invisible. Remove
# only demonstrably stale markers; a live helper keeps the next APP instance
# blocked until it finishes and publishes pending-validation state.
if [ -s "$PORTMASTER_ACTIVE_FILE" ]; then
  active_pid=$(awk -F '\t' '$1 == "pid" {print $2; exit}' "$PORTMASTER_ACTIVE_FILE" 2>/dev/null || true)
  case "$active_pid" in ''|*[!0-9]*) active_pid=0 ;; esac
  if [ "$active_pid" -le 1 ] || ! kill -0 "$active_pid" 2>/dev/null; then
    rm -f -- "$PORTMASTER_ACTIVE_FILE"
    rm -rf -- "$PORTMASTER_ACTIVE_LOCK"
  else
    PORTMASTER_ACTIVE=1
  fi
fi
cd "$PAM_APP_ROOT" || exit 1
if [ "$HEALTH_ONLY" = "1" ] || [ "$INSTALL_PLAN_ONLY" = "1" ]; then
  :
elif [ "$APPLY_ONLY" = "1" ] || [ "$SIZE_ONLY" = "1" ] || [ "$CHECK_UPDATE_ONLY" = "1" ] ||
     [ "$VALIDATE_ONLY" = "1" ] || [ "$RUNTIME_METADATA_ONLY" = "1" ]; then
  exec >> "$GAMEDIR/log.txt" 2>&1
else
  exec > "$GAMEDIR/log.txt" 2>&1
fi

if [ "$APPLY_ONLY" != "1" ] && [ "$SIZE_ONLY" != "1" ] && [ "$CHECK_UPDATE_ONLY" != "1" ] &&
   [ "$VALIDATE_ONLY" != "1" ] && [ "$RUNTIME_METADATA_ONLY" != "1" ] && [ "$INSTALL_PLAN_ONLY" != "1" ]; then
  helper_ready=0
  # MiniLoong 用临时 .port.sh 启动，这个文件可能在执行期间就被
  # 前端移除。Bash 仍在 fd 255 持有已打开的脚本；最后再回退到目录里
  # 稳定的 APP Manager.sh，不假设任何一个文件名在这一瞬间必然存在。
  if [ "$PORTMASTER_ACTIVE" = "0" ]; then
    for helper_source in "$PAM_LAUNCHER_SOURCE" "/proc/$$/fd/255" "$PAM_DIR/APP Manager.sh"; do
      [ -f "$helper_source" ] || continue
      [ "$helper_source" = "$APPLY_HELPER" ] && continue
      if cp -f "$helper_source" "$APPLY_HELPER" 2>/dev/null; then
        helper_ready=1
        break
      fi
    done
  fi
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
[ "$HEALTH_ONLY" = "1" ] || [ "$INSTALL_PLAN_ONLY" = "1" ] ||
  echo "$LOG_PREFIX CFW=$CFW_NAME ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} scripts=$SCRIPTS_DIR gamedirs=$GAMEDIRS_DIR"

pam_miniloong_fonts_complete() {
  local font size
  for font in HK JP KR SC TC; do
    [ -f "$PAM_PORTMASTER_DIR/pylibs/resources/NotoSans${font}-Regular.ttf" ] || return 1
    size=$(wc -c < "$PAM_PORTMASTER_DIR/pylibs/resources/NotoSans${font}-Regular.ttf" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    [ "$size" -gt 1048576 ] || return 1
  done
}

pam_core_health() {
  [ -d "$PAM_PORTMASTER_DIR" ] || { printf missing; return; }
  [ -f "$PAM_PORTMASTER_DIR/control.txt" ] || { printf damaged; return; }
  [ -f "$PAM_PORTMASTER_DIR/device_info.txt" ] || { printf damaged; return; }
  [ -f "$PAM_PORTMASTER_DIR/funcs.txt" ] || { printf damaged; return; }
  [ -f "$PAM_PORTMASTER_DIR/pugwash" ] || [ -f "$PAM_PORTMASTER_DIR/harbourmaster" ] || {
    printf damaged; return;
  }
  case "$PAM_FRONTEND_KIND" in
    trimui)
      [ -x "$PAM_FRONTEND_LAUNCHER" ] || { printf damaged; return; }
      [ -f "$PAM_FRONTEND_DIR/config.json" ] || { printf damaged; return; }
      [ -f "$PAM_FRONTEND_DIR/icon.png" ] || { printf damaged; return; }
      ;;
    script-external)
      [ -x "$PAM_FRONTEND_LAUNCHER" ] || { printf damaged; return; }
      ;;
    control-internal)
      [ -x "$PAM_PORTMASTER_DIR/PortMaster.sh" ] || { printf damaged; return; }
      [ -f "$PAM_FRONTEND_LAUNCHER" ] || { printf damaged; return; }
      ;;
    script-internal)
      [ -x "$PAM_PORTMASTER_DIR/PortMaster.sh" ] || { printf damaged; return; }
      [ -x "$PAM_FRONTEND_LAUNCHER" ] || { printf damaged; return; }
      ;;
    *) printf damaged; return ;;
  esac
  if [ -f "$PAM_PORTMASTER_DIR/pylibs.zip" ]; then
    [ -x "$PAM_BIN_DIR/unzip-portable" ] &&
      "$PAM_BIN_DIR/unzip-portable" -tq "$PAM_PORTMASTER_DIR/pylibs.zip" >/dev/null 2>&1 || {
        printf damaged; return;
      }
  elif [ -d "$PAM_PORTMASTER_DIR/pylibs" ]; then
    [ -n "$(find "$PAM_PORTMASTER_DIR/pylibs" -type f -print -quit 2>/dev/null)" ] || { printf damaged; return; }
    if [ "$PAM_RELEASE_CHANNEL" = "miniloong-custom" ]; then
      pam_miniloong_fonts_complete ||
        [ -s "$PAM_PORTMASTER_DIR/pylibs/resources/NotoSans.tar.xz" ] || {
          printf damaged; return;
        }
    fi
  else
    printf damaged; return
  fi
  pam_portmaster_python_ready || { printf damaged; return; }
  printf healthy
}

pam_system_python_ready() {
  local python_cmd="${PAM_PYTHON3_CMD_OVERRIDE:-python3}"
  command -v "$python_cmd" >/dev/null 2>&1 || return 1
  "$python_cmd" -c 'import sys, encodings, zipfile, hashlib' >/dev/null 2>&1
}

pam_python_runtime_path() {
  printf '%s/python_3.11.squashfs\n' "$LIBS_DIR"
}

pam_python_runtime_basic_ready() {
  local runtime
  runtime=$(pam_python_runtime_path)
  [ -f "$runtime" ] && [ "$(LC_ALL=C head -c 4 "$runtime" 2>/dev/null)" = "hsqs" ]
}

pam_portmaster_python_ready() {
  # Official device launchers keep ownership of their firmware-specific Python
  # setup. Only a profile that installs our Runtime adapter may use libs here.
  pam_system_python_ready ||
    [ "${PAM_PYTHON_RUNTIME_FALLBACK:-0}" != "1" ] ||
    pam_python_runtime_basic_ready
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
  "runtime_metadata_file": "$(json_escape "$RUNTIME_METADATA")",
  "app_root": "$(json_escape "$PAM_APP_ROOT")",
  "portmaster_health": "$(json_escape "$(pam_core_health)")",
  "portmaster_version": "$(json_escape "$(pam_core_version)")",
  "portmaster_target": "$(json_escape "$PAM_PORTMASTER_DIR")",
  "portmaster_release_channel": "$(json_escape "$PAM_RELEASE_CHANNEL")",
  "portmaster_frontend_kind": "$(json_escape "$PAM_FRONTEND_KIND")",
  "portmaster_frontend_dir": "$(json_escape "$PAM_FRONTEND_DIR")",
  "portmaster_frontend_launcher": "$(json_escape "$PAM_FRONTEND_LAUNCHER")",
  "portmaster_frontend_names": "$(json_escape "$PAM_FRONTEND_NAMES")",
  "device_name": "$(json_escape "$PAM_DEVICE_NAME")",
  "device_class": "$(json_escape "$PAM_DEVICE_CLASS")",
  "target_confirmed": "$(json_escape "$PAM_TARGET_CONFIRMED")",
  "pending_install": "$(json_escape "$CONFDIR/pending-install.tsv")",
  "install_transaction": "$(json_escape "$CONFDIR/install-transaction.tsv")",
  "portmaster_active": "$(json_escape "$PORTMASTER_ACTIVE_FILE")",
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
# Runtime repair refreshes PortMaster's official release `ports.json`, the same
# metadata source used by PortMaster itself. Only a state cache is retained;
# the APP package carries no Runtime inventory.
RUNTIME_PROGRESS_COUNT=0
RUNTIME_PROGRESS_INDEX=0
RUNTIME_PROGRESS_TOTAL_BYTES=0
RUNTIME_PROGRESS_DONE_BYTES=0
RUNTIME_PROGRESS_RUNTIME=""
RUNTIME_PROGRESS_SOURCE_BASE=0
RUNTIME_PROGRESS_DETAIL=""
PORTMASTER_PROGRESS=0
PORTMASTER_PROGRESS_FLOOR=0
PORTMASTER_BOOTSTRAP_PROGRESS=0
PORTMASTER_BOOTSTRAP_BYTES=0

runtime_progress_write() {
  local phase="${1:-preparing}" current="${2:-0}" speed="${3:-0}" detail="${4:-}" tmp
  [ "$RUNTIME_PROGRESS_COUNT" -gt 0 ] || return 0
  case "$current" in ""|*[!0-9]*) current=0 ;; esac
  case "$speed" in ""|*[!0-9]*) speed=0 ;; esac
  if [ "$PORTMASTER_BOOTSTRAP_PROGRESS" = "1" ] && [ "$PORTMASTER_BOOTSTRAP_BYTES" -gt 0 ]; then
    current=$((2 + (current * 33 / PORTMASTER_BOOTSTRAP_BYTES)))
    [ "$current" -le 35 ] || current=35
    case "$phase" in
      probing|connected) detail="Checking Python download" ;;
      downloading) detail="Downloading Python" ;;
      verifying) detail="Checking Python" ;;
      installing|finished) detail="Installing Python" ;;
      failed) detail="Python installation failed" ;;
    esac
  elif [ "$PORTMASTER_PROGRESS" = "1" ] && [ "$PORTMASTER_PROGRESS_FLOOR" -gt 0 ]; then
    current=$((PORTMASTER_PROGRESS_FLOOR + (current * (100 - PORTMASTER_PROGRESS_FLOOR) / 100)))
  fi
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

runtime_metadata_field() {
  local runtime="$1" field="$2" arch
  arch=$(runtime_arch)
  [ -f "$RUNTIME_METADATA" ] || return 1
  awk -F '\t' -v runtime="$runtime" -v arch="$arch" -v field="$field" \
    '$1 == runtime && $2 == arch { print $field; exit }' "$RUNTIME_METADATA"
}

runtime_expected_size() { runtime_metadata_field "$1" 3; }
runtime_expected_md5() { runtime_metadata_field "$1" 4; }
runtime_download_url() { runtime_metadata_field "$1" 5; }

runtime_valid_download_url() {
  case "$1" in
    "$PAM_RUNTIME_RELEASES_URL"/download/*/*.squashfs) return 0 ;;
  esac
  return 1
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

runtime_metadata_parse() {
  local source="$1" output="$2"
  awk '
    function value(line) {
      sub(/^[^:]*:[[:space:]]*"/, "", line)
      sub(/",?[[:space:]]*$/, "", line)
      return line
    }
    /^  "utils": \{/ { in_utils=1; next }
    in_utils && /^  \}/ { exit }
    in_utils && /^    "[^"]+": \{/ {
      in_item=1; runtime=""; arch=""; size=""; md5=""; url=""; next
    }
    in_item && /^      "runtime_name": "/ { runtime=value($0); next }
    in_item && /^      "runtime_arch": "/ { arch=value($0); next }
    in_item && /^      "size": [0-9]+/ {
      size=$0; sub(/^[^:]*:[[:space:]]*/, "", size); sub(/,.*/, "", size); next
    }
    in_item && /^      "md5": "/ { md5=value($0); next }
    in_item && /^      "url": "/ { url=value($0); next }
    in_item && /^    \},?$/ {
      if (runtime != "" && arch != "" && size ~ /^[0-9]+$/ &&
          md5 ~ /^[0-9a-fA-F]+$/ && length(md5) == 32 && url != "") {
        sub(/\.squashfs$/, "", runtime)
        print runtime "\t" arch "\t" size "\t" tolower(md5) "\t" url
      }
      in_item=0
    }
  ' "$source" > "$output"
  [ -s "$output" ] || return 1
  awk -F '\t' '
    NF != 5 || $1 !~ /^[A-Za-z0-9._+-]+$/ ||
    $2 !~ /^(aarch64|armhf|x86_64)$/ || $3 !~ /^[0-9]+$/ ||
    $4 !~ /^[0-9a-f]+$/ || length($4) != 32 ||
    $5 !~ /^https:\/\/github.com\/PortsMaster\/PortMaster-New\/releases\/download\/[^\/]+\/[A-Za-z0-9._+-]+\.squashfs$/ { exit 1 }
  ' "$output"
}

runtime_metadata_refresh() {
  local force="${1:-0}" now mtime root json_tmp metadata_tmp
  if [ "$force" != "1" ] && [ -s "$RUNTIME_METADATA" ]; then
    now=$(date +%s 2>/dev/null || printf 0)
    mtime=$(pam_cache_mtime "$RUNTIME_METADATA")
    case "$now:$mtime" in *[!0-9:]*|:) mtime=0 ;; esac
    [ "$mtime" -le 0 ] || [ $((now - mtime)) -ge 86400 ] || return 0
  fi
  root="$CONFDIR/runtime-metadata.$$"
  rm -rf -- "$root"; mkdir -p "$root" || return 1
  json_tmp="$root/ports.json"; metadata_tmp="$root/runtime-metadata.tsv"
  GITHUB_PROXY_TRANSFER_MODE="plain"
  if github_proxy_download release "$RUNTIME_METADATA_URL" "$json_tmp" runtime_validate_metadata_download 0 0 &&
     runtime_metadata_parse "$json_tmp" "$metadata_tmp"; then
    mv -f -- "$metadata_tmp" "$RUNTIME_METADATA"
  else
    rm -rf -- "$root"
    [ "$force" != "1" ] && [ -s "$RUNTIME_METADATA" ]
    return
  fi
  rm -rf -- "$root"
  return 0
}

runtime_validate_metadata_download() {
  local parsed="$1.parsed.$$" rc
  runtime_metadata_parse "$1" "$parsed"; rc=$?
  rm -f -- "$parsed"
  return "$rc"
}

pam_stable_field_from_json() {
  local field="$2"
  awk -v field="$field" '
    /"stable"[[:space:]]*:/ { stable=1; next }
    stable && $0 ~ "\"" field "\"[[:space:]]*:" {
      line=$0
      sub(/^[^:]*:[[:space:]]*"/, "", line)
      sub(/".*/, "", line)
      print line
      exit
    }
  ' "$1"
}

pam_stable_version_from_json() { pam_stable_field_from_json "$1" version; }

pm_validate_version_download() {
  local version url
  version=$(pam_stable_version_from_json "$1" 2>/dev/null || true)
  case "$version" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac
  url=$(pam_stable_field_from_json "$1" url 2>/dev/null || true)
  pm_valid_custom_stable_archive_url "$url" || return 1
  case "$url" in */releases/download/"$version"/PortMaster.zip) ;; *) return 1 ;; esac
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
  else
    pm_download_url release "$PAM_RELEASE_BASE/version.json" "$tmp" 0 0 pm_validate_version_download || true
  fi
  latest=$(pam_stable_version_from_json "$tmp" 2>/dev/null || true)
  case "$latest" in ""|*[!A-Za-z0-9._-]*) latest="" ;; *) status="ok" ;; esac
  printf '%s\t%s\t%s\n' "$now" "$status" "$latest" > "$UPDATE_CACHE_FILE.tmp" &&
    mv -f "$UPDATE_CACHE_FILE.tmp" "$UPDATE_CACHE_FILE"
  rm -f -- "$tmp"
  [ "$status" = "ok" ]
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

pm_cancel_requested() { [ -e "$CANCEL_FILE" ]; }

pm_fetch_url() {
  local url="$1" out="$2" start="$3" finish="$4" fetch_pid monitor_pid rc=0
  local before started now current elapsed transferred final_speed=0 final_detail speed_file
  runtime_prepare_downloader || return 1
  before=$(runtime_file_size "$out")
  started=$(date +%s)
  speed_file="$CONFDIR/.pm-speed.$$"
  rm -f -- "$speed_file"
  "$RUNTIME_CURL" -fsSL --connect-timeout 8 --retry 2 --retry-delay 1 -C - -o "$out" "$url" 2>/dev/null &
  fetch_pid=$!
  (
    local now last_time last_size current delta elapsed span percent speed
    last_time=$(date +%s); last_size=$before
    while kill -0 "$fetch_pid" 2>/dev/null; do
      sleep 1
      if pm_cancel_requested; then kill "$fetch_pid" 2>/dev/null || true; exit 70; fi
      now=$(date +%s); current=$(runtime_file_size "$out")
      elapsed=$((now - last_time)); delta=$((current - last_size)); [ "$elapsed" -gt 0 ] || elapsed=1
      [ "$delta" -ge 0 ] || delta=0
      speed=$((delta / elapsed))
      [ "$speed" -le 0 ] || printf '%s\n' "$speed" > "$speed_file"
      span=$((finish - start)); percent=$start
      if [ "$current" -gt "$before" ]; then percent=$((start + span / 2)); fi
      runtime_progress_write downloading "$percent" "$speed" "Downloading verified release assets"
      last_time=$now; last_size=$current
    done
  ) &
  monitor_pid=$!
  wait "$fetch_pid" || rc=$?
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  if pm_cancel_requested; then rm -f -- "$speed_file"; return 70; fi
  if [ "$rc" != "0" ]; then rm -f -- "$speed_file"; return "$rc"; fi
  now=$(date +%s); current=$(runtime_file_size "$out")
  elapsed=$((now - started)); [ "$elapsed" -gt 0 ] || elapsed=1
  transferred=$((current - before)); [ "$transferred" -ge 0 ] || transferred=0
  if [ -s "$speed_file" ]; then final_speed=$(sed -n '1p' "$speed_file" 2>/dev/null || echo 0); fi
  case "$final_speed" in ""|*[!0-9]*) final_speed=0 ;; esac
  if [ "$transferred" -gt 0 ]; then
    [ "$final_speed" -gt 0 ] || final_speed=$((transferred / elapsed))
    final_detail="Downloading verified release assets"
  elif [ "$before" -gt 0 ]; then
    final_detail="Using local cache"
  else
    final_detail="Download complete"
  fi
  rm -f -- "$speed_file"
  runtime_progress_write downloading "$finish" "$final_speed" "$final_detail"
}

# One transport adapter serves PortMaster releases, repository files and
# Runtime assets. The proxy module owns capability filtering and route
# fallback; this layer contributes only APP-specific progress and validation.
github_proxy_transfer_hook() {
  local url="$1" out="$2" resume=0
  case "${GITHUB_PROXY_TRANSFER_MODE:-plain}" in
    portmaster)
      pm_fetch_url "$url" "$out" "$GITHUB_PROXY_PROGRESS_START" "$GITHUB_PROXY_PROGRESS_FINISH"
      ;;
    runtime)
      [ -s "$out" ] && resume=1
      runtime_fetch_url "$url" "$out" "$resume"
      ;;
    plain)
      runtime_prepare_downloader || return 1
      if [ -s "$out" ]; then
        "$RUNTIME_CURL" -fsSL --connect-timeout 8 --max-time 60 --retry 2 --retry-delay 1 -C - -o "$out" "$url" 2>/dev/null
      else
        "$RUNTIME_CURL" -fsSL --connect-timeout 8 --max-time 60 --retry 2 --retry-delay 1 -o "$out" "$url" 2>/dev/null
      fi
      ;;
    *) return 1 ;;
  esac
}

github_proxy_download() {
  local capability="$1" source="$2" out="$3" validator="$4" start="$5" finish="$6" mode="${7:-plain}"
  runtime_prepare_downloader || return 1
  GITHUB_PROXY_CURL="$RUNTIME_CURL"
  GITHUB_PROXY_TRANSFER_MODE="$mode"
  GITHUB_PROXY_PROGRESS_START="$start"
  GITHUB_PROXY_PROGRESS_FINISH="$finish"
  runtime_progress_write probing "$start" 0 "Checking connection"
  github_proxy_fetch "$capability" "$source" "$out" "$validator"
}

pm_download_url() {
  github_proxy_download "$1" "$2" "$3" "$6" "$4" "$5" portmaster
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
  for asset in version.json PortMaster.zip; do
    [ -n "$(pm_checksum_expected "$sums" "$asset")" ] || return 1
  done
}

pam_write_install_plan() {
  local plan="$1" tmp="$plan.tmp.$$"
  local names primary control_source core_source frontend_map remove_core empty_tasksetter
  local core_executable frontend_executable
  [ "$PAM_TARGET_CONFIRMED" = "1" ] || return 1
  for path in "$PAM_PORTMASTER_DIR" "$SCRIPTS_DIR" "$PAM_FRONTEND_DIR"; do
    case "$path" in
      /|""|*'//'|/*/../*|/*/..|/../*|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;;
      /*) ;;
      *) return 1 ;;
    esac
  done
  case "${param_device:-}" in
    trimui)
      names='launch.sh,config.json,icon.png'; primary='launch.sh'
      control_source='trimui/control.txt'; core_source='-'
      frontend_map='trimui/PortMaster.txt=launch.sh,trimui/config.json=config.json,trimui/icon.png=icon.png'
      remove_core=1; empty_tasksetter=1; core_executable='-'; frontend_executable='launch.sh'
      ;;
    muos)
      names='control.txt'; primary='control.txt'; control_source='muos/control.txt'; core_source='muos/PortMaster.txt'
      frontend_map='muos/control.txt=control.txt'
      remove_core=0; empty_tasksetter=1; core_executable='PortMaster.sh'; frontend_executable='-'
      ;;
    batocera|knulli)
      names='PortMaster.sh'; primary='PortMaster.sh'; control_source="$param_device/control.txt"; core_source='-'
      frontend_map='PortMaster.sh=PortMaster.sh'
      remove_core=1; empty_tasksetter=1; core_executable='-'; frontend_executable='PortMaster.sh'
      ;;
    miyoo)
      names='control.txt'; primary='control.txt'; control_source='miyoo/control.txt'; core_source='miyoo/PortMaster.txt'
      frontend_map='miyoo/control.txt=control.txt'
      remove_core=0; empty_tasksetter=0; core_executable='PortMaster.sh'; frontend_executable='-'
      ;;
    miniloong)
      names='PortMaster.sh'; primary='PortMaster.sh'; control_source='-'; core_source='-'
      frontend_map='miniloong/PortMaster.txt=PortMaster.sh'
      remove_core=0; empty_tasksetter=0; core_executable='PortMaster.sh'; frontend_executable='PortMaster.sh'
      ;;
    generic)
      names='PortMaster.sh'; primary='PortMaster.sh'; control_source='-'; core_source='-'
      frontend_map='PortMaster.sh=PortMaster.sh'
      remove_core=0; empty_tasksetter=0; core_executable='PortMaster.sh'; frontend_executable='PortMaster.sh'
      ;;
    *) return 1 ;;
  esac
  [ "$PAM_FRONTEND_NAMES" = "$names" ] || return 1
  [ "$PAM_FRONTEND_LAUNCHER" = "$PAM_FRONTEND_DIR/$primary" ] || return 1
  {
    printf 'schema\t1\n'
    printf 'device\t%s\n' "$param_device"
    printf 'target\t%s\n' "$PAM_PORTMASTER_DIR"
    printf 'scripts\t%s\n' "$SCRIPTS_DIR"
    printf 'frontend_dir\t%s\n' "$PAM_FRONTEND_DIR"
    printf 'frontend_names\t%s\n' "$names"
    printf 'primary_frontend\t%s\n' "$primary"
    printf 'control_source\t%s\n' "$control_source"
    printf 'core_launcher_source\t%s\n' "$core_source"
    printf 'frontend_map\t%s\n' "$frontend_map"
    printf 'remove_core_launcher\t%s\n' "$remove_core"
    printf 'empty_tasksetter\t%s\n' "$empty_tasksetter"
    printf 'core_executable\t%s\n' "$core_executable"
    printf 'frontend_executable\t%s\n' "$frontend_executable"
  } > "$tmp" && mv -f -- "$tmp" "$plan"
}

pm_validate_installer() {
  local installer="$1"
  [ -s "$installer" ] || return 1
  grep -Fqx '# PAM_INSTALLER_PROTOCOL=1' "$installer" || return 1
  grep -Fqx '# PAM_PROFILE_SCHEMA=1' "$installer" || return 1
  bash -n "$installer" >/dev/null 2>&1
}

pm_valid_custom_stable_archive_url() {
  case "$1" in
    "$PAM_FORK_RELEASES_URL"/download/*/PortMaster.zip) return 0 ;;
  esac
  return 1
}

pm_official_md5_expected() {
  awk '{ name=$2; sub(/^\*/, "", name); if ($1 ~ /^[0-9A-Fa-f]{32}$/ && (name == "" || name == "PortMaster.zip")) {print tolower($1); exit} }' "$1"
}

pm_validate_md5_download() {
  local expected
  expected=$(pm_official_md5_expected "$1")
  [ "${#expected}" = 32 ]
}

pm_validate_archive_download() {
  local actual
  if [ "${PM_ARCHIVE_HASH_KIND:-sha256}" = "md5" ]; then
    actual=$(runtime_md5_file "$1" 2>/dev/null || true)
  else
    actual=$(pm_sha256_file "$1" 2>/dev/null || true)
  fi
  [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = "$PM_EXPECTED_ARCHIVE_HASH" ]
}

install_portmaster_release_inner() {
  local cache="$CONFDIR/portmaster-download" sums version installer installer_tmp install_plan archive archive_dir checksum rc
  local version_url stable_url stable_version expected_hash actual_hash archive_valid=0 reason
  sums="$cache/SHA256SUMS"; version="$cache/version.json"
  installer="$cache/appmanager-installer.sh"; installer_tmp="$installer.new"
  install_plan="$cache/portmaster-install-plan.tsv"
  rm -f -- "$CANCEL_FILE"; mkdir -p "$cache" || return 1
  rm -f -- "$sums" "$version" "$installer_tmp" "$install_plan"
  RUNTIME_PROGRESS_RUNTIME="PortMaster"
  runtime_progress_write preparing 1 0 "Preparing PortMaster"
  ensure_portmaster_python_runtime || {
    printf 'FAIL\tportmaster\tpython-runtime\n' >> "$RESULT_FILE"
    return 1
  }
  version_url="$PAM_RELEASE_BASE/version.json"
  pm_download_url release "$version_url" "$version" 5 10 pm_validate_version_download || { rc=$?; printf 'FAIL\tportmaster\t%s\n' "$([ "$rc" = 70 ] && echo cancelled || echo network)" >> "$RESULT_FILE"; return 1; }
  pm_download_url release "$PAM_CUSTOM_RELEASE_BASE/SHA256SUMS" "$sums" 10 14 pm_validate_sums || { printf 'FAIL\tportmaster\tnetwork\n' >> "$RESULT_FILE"; return 1; }
  pm_validate_sums "$sums" || { printf 'FAIL\tportmaster\tchecksums\n' >> "$RESULT_FILE"; return 1; }
  pm_verify_asset "$sums" version.json "$version" || { printf 'FAIL\tportmaster\tchecksum\n' >> "$RESULT_FILE"; return 1; }
  stable_version=$(pam_stable_version_from_json "$version" 2>/dev/null || true)
  stable_url=$(pam_stable_field_from_json "$version" url 2>/dev/null || true)
  case "$stable_version" in ""|*[!A-Za-z0-9._-]*) printf 'FAIL\tportmaster\tversion\n' >> "$RESULT_FILE"; return 1 ;; esac
  pm_valid_custom_stable_archive_url "$stable_url" || { printf 'FAIL\tportmaster\tversion-url\n' >> "$RESULT_FILE"; return 1; }
  case "$stable_url" in */releases/download/"$stable_version"/PortMaster.zip) ;; *) printf 'FAIL\tportmaster\tversion-url\n' >> "$RESULT_FILE"; return 1 ;; esac
  archive_dir="$cache/$stable_version"; archive="$archive_dir/PortMaster.zip"
  mkdir -p "$archive_dir" || return 1

  # The APP owns profile/path discovery. The branch-maintained helper receives
  # only that normalized plan and contains no device detection of its own.
  pm_download_url raw "$PAM_INSTALLER_SOURCE_URL" "$installer_tmp" 14 20 pm_validate_installer || {
    rc=$?
    case "$rc" in 70) reason=cancelled ;; 65) reason=installer-contract ;; *) reason=network ;; esac
    printf 'FAIL\tportmaster\t%s\n' "$reason" >> "$RESULT_FILE"; return 1
  }
  chmod 0700 "$installer_tmp" && mv -f -- "$installer_tmp" "$installer" || return 1

  if [ "$PAM_RELEASE_CHANNEL" = "miniloong-custom" ]; then
    expected_hash=$(pm_checksum_expected "$sums" PortMaster.zip)
  else
    stable_url="$PAM_OFFICIAL_RELEASES_URL/download/$stable_version/PortMaster.zip"
    checksum="$archive_dir/PortMaster.zip.md5"
    rm -f -- "$checksum"
    pm_download_url release "$stable_url.md5" "$checksum" 18 20 pm_validate_md5_download || { printf 'FAIL\tportmaster\tnetwork\n' >> "$RESULT_FILE"; return 1; }
    expected_hash=$(pm_official_md5_expected "$checksum")
    [ "${#expected_hash}" = 32 ] || { printf 'FAIL\tportmaster\tversion-md5\n' >> "$RESULT_FILE"; return 1; }
  fi
  if [ -s "$archive" ]; then
    if [ "$PAM_RELEASE_CHANNEL" = "miniloong-custom" ]; then actual_hash=$(pm_sha256_file "$archive" 2>/dev/null || true)
    else actual_hash=$(runtime_md5_file "$archive" 2>/dev/null || true); fi
    [ "$(printf '%s' "$actual_hash" | tr '[:upper:]' '[:lower:]')" = "$expected_hash" ] && archive_valid=1
  fi
  if [ "$archive_valid" = "1" ]; then
    runtime_progress_write downloading 78 0 "Using local cache"
  else
    PM_EXPECTED_ARCHIVE_HASH="$expected_hash"
    if [ "$PAM_RELEASE_CHANNEL" = "miniloong-custom" ]; then PM_ARCHIVE_HASH_KIND="sha256"
    else PM_ARCHIVE_HASH_KIND="md5"; fi
    pm_download_url release "$stable_url" "$archive" 20 78 pm_validate_archive_download || {
      rc=$?
      case "$rc" in 70) reason=cancelled ;; 65) reason=checksum ;; *) reason=network ;; esac
      printf 'FAIL\tportmaster\t%s\n' "$reason" >> "$RESULT_FILE"; return 1
    }
  fi
  runtime_progress_write verifying 82 0 "Verifying release assets"
  if [ "$PAM_RELEASE_CHANNEL" = "miniloong-custom" ]; then actual_hash=$(pm_sha256_file "$archive" 2>/dev/null || true)
  else actual_hash=$(runtime_md5_file "$archive" 2>/dev/null || true); fi
  if [ "$(printf '%s' "$actual_hash" | tr '[:upper:]' '[:lower:]')" != "$expected_hash" ]; then
    # A completed but invalid file is never retained. Retry once without a
    # range so a bad cache cannot poison later launches.
    rm -f -- "$archive"
    pm_download_url release "$stable_url" "$archive" 20 78 pm_validate_archive_download || {
      rc=$?
      case "$rc" in 70) reason=cancelled ;; 65) reason=checksum ;; *) reason=network ;; esac
      printf 'FAIL\tportmaster\t%s\n' "$reason" >> "$RESULT_FILE"; return 1
    }
    if [ "$PAM_RELEASE_CHANNEL" = "miniloong-custom" ]; then actual_hash=$(pm_sha256_file "$archive" 2>/dev/null || true)
    else actual_hash=$(runtime_md5_file "$archive" 2>/dev/null || true); fi
    [ "$(printf '%s' "$actual_hash" | tr '[:upper:]' '[:lower:]')" = "$expected_hash" ] || {
      rm -f -- "$archive"; printf 'FAIL\tportmaster\tchecksum\n' >> "$RESULT_FILE"; return 1;
    }
  fi
  if [ ! -s "$archive" ]; then
    echo "$LOG_PREFIX cached PortMaster archive did not match the current stable release; restarting"
    rm -f -- "$archive"
    printf 'FAIL\tportmaster\tchecksum\n' >> "$RESULT_FILE"; return 1
  fi
  [ -x "$PAM_BIN_DIR/unzip-portable" ] || { printf 'FAIL\tportmaster\tunzip\n' >> "$RESULT_FILE"; return 1; }
  "$PAM_BIN_DIR/unzip-portable" -t "$archive" >/dev/null 2>&1 || {
    printf 'FAIL\tportmaster\tarchive\n' >> "$RESULT_FILE"; return 1;
  }
  pm_cancel_requested && { printf 'FAIL\tportmaster\tcancelled\n' >> "$RESULT_FILE"; return 1; }
  pam_write_install_plan "$install_plan" || { printf 'FAIL\tportmaster\tinstall-plan\n' >> "$RESULT_FILE"; return 1; }
  runtime_progress_write installing 88 0 "Installing PortMaster"
  PAM_CANCEL_FILE="$CANCEL_FILE" PAM_UNZIP="$PAM_BIN_DIR/unzip-portable" \
    PAM_SHA256="$PAM_BIN_DIR/sha256sum-portable" \
    bash "$installer" --archive "$archive" --plan "$install_plan" --state-dir "$CONFDIR" || {
        rc=$?; printf 'FAIL\tportmaster\tinstaller-%s\n' "$rc" >> "$RESULT_FILE"; return 1;
      }
  [ -s "$CONFDIR/pending-install.tsv" ] && [ -s "$CONFDIR/pending-manifest.tsv" ] &&
    [ -s "$CONFDIR/pending-frontend-manifest.tsv" ] || {
    printf 'FAIL\tportmaster\tpending-validation\n' >> "$RESULT_FILE"; return 1;
  }
  runtime_progress_write complete 100 0 "Installation complete; reopen required"
  printf 'OK\tportmaster\tpending-validation\n' >> "$RESULT_FILE"
}

install_portmaster_release() {
  local existing_pid rc
  if ! mkdir "$PORTMASTER_ACTIVE_LOCK" 2>/dev/null; then
    existing_pid=$(awk -F '\t' '$1 == "pid" {print $2; exit}' "$PORTMASTER_ACTIVE_FILE" 2>/dev/null || true)
    case "$existing_pid" in ''|*[!0-9]*) existing_pid=0 ;; esac
    if [ "$existing_pid" -gt 1 ] && kill -0 "$existing_pid" 2>/dev/null; then
      printf 'FAIL\tportmaster\talready-running\n' >> "$RESULT_FILE"
      return 1
    fi
    rm -rf -- "$PORTMASTER_ACTIVE_LOCK" || return 1
    mkdir "$PORTMASTER_ACTIVE_LOCK" || return 1
  fi
  {
    printf 'version\t1\n'
    printf 'pid\t%s\n' "$$"
    printf 'started\t%s\n' "$(date +%s 2>/dev/null || echo 0)"
  } > "$PORTMASTER_ACTIVE_FILE.tmp.$$" &&
    mv -f -- "$PORTMASTER_ACTIVE_FILE.tmp.$$" "$PORTMASTER_ACTIVE_FILE" || {
      rm -rf -- "$PORTMASTER_ACTIVE_LOCK"
      return 1
    }
  install_portmaster_release_inner; rc=$?
  rm -f -- "$PORTMASTER_ACTIVE_FILE"
  rm -rf -- "$PORTMASTER_ACTIVE_LOCK"
  return "$rc"
}

runtime_download_source() {
  local official_url="$1" expected="$2" out="$3" actual rc
  runtime_valid_download_url "$official_url" || return 1
  case "$expected" in ""|*[!0-9]*|0) return 1 ;; esac
  if [ -L "$out" ]; then rm -f -- "$out" || return 1; fi
  actual=$(runtime_file_size "$out")
  if [ "$actual" = "$expected" ] && runtime_validate_download "$out"; then
    echo "$LOG_PREFIX using complete Runtime cache"
    [ -n "${RUNTIME_DOWNLOAD_VIA:-}" ] || RUNTIME_DOWNLOAD_VIA="Cache"
    runtime_progress_write downloading "$((RUNTIME_PROGRESS_SOURCE_BASE + expected))" 0 "Using local cache"
    return 0
  fi
  [ "$actual" = 0 ] || rm -f -- "$out"
  RUNTIME_PROGRESS_DETAIL="Downloading Runtime"
  if github_proxy_download release "$official_url" "$out" runtime_validate_download \
       "$RUNTIME_PROGRESS_DONE_BYTES" "$((RUNTIME_PROGRESS_DONE_BYTES + expected))" runtime; then
    RUNTIME_DOWNLOAD_VIA="network"
    return 0
  else rc=$?; fi
  return "$rc"
}

runtime_md5_file() {
  if [ -x "$PAM_BIN_DIR/busybox-portable" ]; then
    "$PAM_BIN_DIR/busybox-portable" md5sum "$1" | awk '{print tolower($1)}'
  elif command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print tolower($1)}'
  elif command -v md5 >/dev/null 2>&1; then md5 -q "$1" | tr '[:upper:]' '[:lower:]'
  else return 1
  fi
}

runtime_validate_download() {
  [ "$(runtime_file_size "$1")" = "$RUNTIME_EXPECTED_SIZE" ] || return 1
  runtime_has_magic "$1" || return 1
  [ "$(runtime_md5_file "$1" 2>/dev/null || true)" = "$RUNTIME_EXPECTED_MD5" ]
}

install_runtime() {
  local runtime="$1" source_url expected_size expected_md5 actual_md5 target staged cache_root cache_dir download
  local RUNTIME_DOWNLOAD_VIA="" download_rc reason
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
  source_url=$(runtime_download_url "$runtime")
  expected_size=$(runtime_expected_size "$runtime")
  expected_md5=$(runtime_expected_md5 "$runtime")
  if ! runtime_valid_download_url "$source_url" ||
     [[ ! "$expected_size" =~ ^[0-9]+$ ]] || [ "$expected_size" -le 0 ] ||
     [[ ! "$expected_md5" =~ ^[0-9a-f]{32}$ ]]; then
    printf 'FAIL\truntime\t%s\tunsupported\n' "$runtime" >> "$RESULT_FILE"
    return 1
  fi
  runtime_progress_write preparing "$RUNTIME_PROGRESS_DONE_BYTES" 0 "$runtime"
  cache_root="$CONFDIR/runtime-cache"
  cache_dir="$cache_root/$expected_md5"
  if [ -L "$cache_root" ] || [ -L "$cache_dir" ]; then
    printf 'FAIL\truntime\t%s\tcache-dir\n' "$runtime" >> "$RESULT_FILE"
    return 1
  fi
  mkdir -p "$cache_dir" || {
    printf 'FAIL\truntime\t%s\tcache-dir\n' "$runtime" >> "$RESULT_FILE"
    return 1
  }
  download="$cache_dir/runtime.download"
  RUNTIME_PROGRESS_SOURCE_BASE=$RUNTIME_PROGRESS_DONE_BYTES
  RUNTIME_EXPECTED_SIZE="$expected_size"
  RUNTIME_EXPECTED_MD5="$expected_md5"
  if [ -L "$download" ]; then rm -f -- "$download" || return 1; fi
  if runtime_download_source "$source_url" "$expected_size" "$download"; then :
  else
    download_rc=$?
    if [ "$download_rc" = 65 ]; then reason=checksum
    elif [ "$download_rc" = 70 ]; then reason=cancelled
    else reason=download; fi
    printf 'FAIL\truntime\t%s\t%s\n' "$runtime" "$reason" >> "$RESULT_FILE"
    return 1
  fi
  runtime_progress_write verifying "$((RUNTIME_PROGRESS_DONE_BYTES + expected_size))" 0 "$runtime"
  if ! runtime_has_magic "$download"; then
    printf 'FAIL\truntime\t%s\tinvalid-image\n' "$runtime" >> "$RESULT_FILE"
    rm -rf "$cache_dir"; return 1
  fi
  actual_md5=$(runtime_md5_file "$download" 2>/dev/null || true)
  if [ "$actual_md5" != "$expected_md5" ]; then
    printf 'FAIL\truntime\t%s\tchecksum\n' "$runtime" >> "$RESULT_FILE"
    rm -rf "$cache_dir"; return 1
  fi

  staged="$LIBS_DIR/.pam-$runtime.squashfs.$$"
  runtime_progress_write installing "$((RUNTIME_PROGRESS_DONE_BYTES + expected_size))" 0 "$target"
  if $ESUDO mkdir -p "$LIBS_DIR" &&
     $ESUDO mv -- "$download" "$staged" &&
     $ESUDO chmod 0644 "$staged" &&
     $ESUDO mv -f -- "$staged" "$target"; then
    printf 'OK\truntime\t%s\t%s\n' "$runtime" "${RUNTIME_DOWNLOAD_VIA:-network}" >> "$RESULT_FILE"
    echo "$LOG_PREFIX Runtime installed: $runtime"
    rm -rf "$cache_dir"
    return 0
  fi
  $ESUDO rm -f -- "$staged" 2>/dev/null || true
  printf 'FAIL\truntime\t%s\tinstall\n' "$runtime" >> "$RESULT_FILE"
  return 1
}

runtime_matches_current_metadata() {
  local runtime="$1" target expected_size expected_md5 actual_size actual_md5
  target="$LIBS_DIR/$runtime.squashfs"
  expected_size=$(runtime_expected_size "$runtime")
  expected_md5=$(runtime_expected_md5 "$runtime")
  case "$expected_size" in ""|*[!0-9]*|0) return 1 ;; esac
  [[ "$expected_md5" =~ ^[0-9a-f]{32}$ ]] || return 1
  runtime_has_magic "$target" || return 1
  actual_size=$(runtime_file_size "$target")
  [ "$actual_size" = "$expected_size" ] || return 1
  actual_md5=$(runtime_md5_file "$target" 2>/dev/null || true)
  [ "$actual_md5" = "$expected_md5" ]
}

ensure_portmaster_python_runtime() {
  local runtime="python_3.11" expected_size
  pam_system_python_ready && return 0
  [ "${PAM_PYTHON_RUNTIME_FALLBACK:-0}" = "1" ] || return 0

  # A previously verified official Runtime remains a valid Python bootstrap;
  # reinstalling PortMaster must not require the network just to rediscover the
  # same metadata.
  runtime_matches_current_metadata "$runtime" && return 0
  runtime_progress_write probing 2 0 "Checking Python Runtime"
  if ! runtime_metadata_refresh 1; then
    echo "$LOG_PREFIX unable to refresh Python Runtime information"
    return 1
  fi
  runtime_matches_current_metadata "$runtime" && return 0

  expected_size=$(runtime_expected_size "$runtime")
  case "$expected_size" in ""|*[!0-9]*|0) return 1 ;; esac
  PORTMASTER_BOOTSTRAP_BYTES=$expected_size
  PORTMASTER_BOOTSTRAP_PROGRESS=1
  if ! install_runtime "$runtime"; then
    PORTMASTER_BOOTSTRAP_PROGRESS=0
    PORTMASTER_BOOTSTRAP_BYTES=0
    return 1
  fi
  PORTMASTER_BOOTSTRAP_PROGRESS=0
  PORTMASTER_BOOTSTRAP_BYTES=0
  PORTMASTER_PROGRESS_FLOOR=35
  runtime_matches_current_metadata "$runtime"
}

apply_plan() {
  local stamp kind arg dest base bucket batch item trash_failed=0 empty_failed=0 runtime_bytes
  local device_risk_ack=0 device_support_ack=0 runtime_metadata_ready=1
  stamp=$(date +%Y%m%d-%H%M%S)
  : > "$RESULT_FILE"
  rm -f -- "$PROGRESS_FILE" "$PROGRESS_FILE.tmp.$$"
  if [ ! -f "$PLAN_FILE" ]; then
    printf 'FAIL\toperation\n' >> "$RESULT_FILE"
    return
  fi
  if grep -q $'^INSTALL_RUNTIME\t' "$PLAN_FILE" 2>/dev/null; then
    RUNTIME_PROGRESS_COUNT=$(grep -c $'^INSTALL_RUNTIME\t' "$PLAN_FILE" 2>/dev/null || echo 0)
    RUNTIME_PROGRESS_RUNTIME="Runtime"
    runtime_progress_write probing 0 0 "Updating official Runtime information"
    if ! runtime_metadata_refresh 1; then
      runtime_metadata_ready=0
      echo "$LOG_PREFIX unable to refresh official Runtime information"
    fi
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
        if [ "$runtime_metadata_ready" != "1" ]; then
          printf 'FAIL\truntime\t%s\tmetadata\n' "$arg" >> "$RESULT_FILE"
          runtime_progress_write failed "$RUNTIME_PROGRESS_DONE_BYTES" 0 "$arg"
        elif install_runtime "$arg"; then
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
            runtime_progress_write failed 100 0 "PortMaster installation failed"
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

state_value() {
  local file="$1" key="$2"
  awk -F '\t' -v key="$key" '$1 == key {sub(/^[^\t]*\t/, ""); print; count++} END {if (count != 1) exit 1}' "$file"
}

validation_write() {
  local status="$1" detail="$2" tmp="$VALIDATION_RESULT_FILE.tmp.$$"
  detail=${detail//$'\t'/ }; detail=${detail//$'\r'/ }; detail=${detail//$'\n'/ }
  printf '1\t%s\t%s\n' "$status" "$detail" > "$tmp" && mv -f -- "$tmp" "$VALIDATION_RESULT_FILE"
}

pending_manifest_valid() {
  local manifest="$CONFDIR/pending-manifest.tsv" hash relative actual expected_hash expected_count count=0
  [ -s "$manifest" ] || return 1
  expected_hash=$(state_value "$CONFDIR/pending-install.tsv" manifest_sha256) || return 1
  expected_count=$(state_value "$CONFDIR/pending-install.tsv" manifest_count) || return 1
  case "$expected_hash" in *[!0-9A-Fa-f]*|'') return 1 ;; esac
  [ "${#expected_hash}" = 64 ] || return 1
  case "$expected_count" in ''|*[!0-9]*|0) return 1 ;; esac
  actual=$(pm_sha256_file "$manifest" 2>/dev/null || true)
  [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$expected_hash" | tr '[:upper:]' '[:lower:]')" ] || return 1
  while IFS=$'\t' read -r hash relative; do
    case "$hash" in ""|*[!0-9A-Fa-f]*) return 1 ;; esac
    [ "${#hash}" = 64 ] || return 1
    case "$relative" in ""|/*|../*|*/../*|*/..) return 1 ;; esac
    [ -f "$PAM_PORTMASTER_DIR/$relative" ] || return 1
    actual=$(pm_sha256_file "$PAM_PORTMASTER_DIR/$relative" 2>/dev/null || true)
    [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = \
      "$(printf '%s' "$hash" | tr '[:upper:]' '[:lower:]')" ] || return 1
    count=$((count + 1))
  done < "$manifest"
  [ "$count" = "$expected_count" ]
}

frontend_name_allowed() {
  case ",$PAM_FRONTEND_NAMES," in *",$1,"*) return 0 ;; esac
  return 1
}

pending_frontend_manifest_valid() {
  local file="$CONFDIR/pending-install.tsv" manifest="$CONFDIR/pending-frontend-manifest.tsv"
  local expected_hash expected_count actual hash name count=0
  [ -s "$manifest" ] || return 1
  expected_hash=$(state_value "$file" frontend_manifest_sha256) || return 1
  expected_count=$(state_value "$file" frontend_manifest_count) || return 1
  case "$expected_hash" in *[!0-9A-Fa-f]*|'') return 1 ;; esac
  [ "${#expected_hash}" = 64 ] || return 1
  case "$expected_count" in ''|*[!0-9]*|0) return 1 ;; esac
  actual=$(pm_sha256_file "$manifest" 2>/dev/null || true)
  [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$expected_hash" | tr '[:upper:]' '[:lower:]')" ] || return 1
  while IFS=$'\t' read -r hash name; do
    case "$hash" in ""|*[!0-9A-Fa-f]*) return 1 ;; esac
    [ "${#hash}" = 64 ] || return 1
    case "$name" in ""|*/*|.|..) return 1 ;; esac
    frontend_name_allowed "$name" || return 1
    [ -f "$PAM_FRONTEND_DIR/$name" ] || return 1
    actual=$(pm_sha256_file "$PAM_FRONTEND_DIR/$name" 2>/dev/null || true)
    [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = \
      "$(printf '%s' "$hash" | tr '[:upper:]' '[:lower:]')" ] || return 1
    count=$((count + 1))
  done < "$manifest"
  [ "$count" = "$expected_count" ]
}

pending_core_valid() {
  local file="$CONFDIR/pending-install.tsv" expected_target expected_scripts expected_device expected_rollback
  local version metadata_version mode launcher_hash actual expected_frontend_dir expected_frontend_names
  metadata_version=$(state_value "$file" version) || return 1
  mode=$(state_value "$file" mode) || return 1
  expected_target=$(state_value "$file" target) || return 1
  expected_scripts=$(state_value "$file" scripts) || return 1
  expected_device=$(state_value "$file" device) || return 1
  expected_rollback=$(state_value "$file" rollback) || return 1
  launcher_hash=$(state_value "$file" launcher_sha256) || return 1
  case "$metadata_version" in 2|3) ;; *) return 1 ;; esac
  case "$mode" in install|update) ;; *) return 1 ;; esac
  [ -n "$expected_target" ] && [ "$expected_target" = "$PAM_PORTMASTER_DIR" ] || return 1
  [ -n "$expected_scripts" ] && [ "$expected_scripts" = "$SCRIPTS_DIR" ] || return 1
  [ "$expected_rollback" = "$PAM_PORTMASTER_DIR/.appmanager-rollback" ] || return 1
  if [ "$metadata_version" = "3" ]; then
    expected_frontend_dir=$(state_value "$file" frontend_dir) || return 1
    expected_frontend_names=$(state_value "$file" frontend_names) || return 1
    [ "$expected_frontend_dir" = "$PAM_FRONTEND_DIR" ] || return 1
    [ "$expected_frontend_names" = "$PAM_FRONTEND_NAMES" ] || return 1
  fi
  case "$launcher_hash" in *[!0-9A-Fa-f]*|'') return 1 ;; esac
  [ "${#launcher_hash}" = 64 ] || return 1
  case "$expected_device" in miniloong|trimui|muos|batocera|knulli|miyoo|generic|unknown|official-untested|unsupported|unsupported-known) ;; *) return 1 ;; esac
  case "$expected_device" in
    miniloong) [ "$param_device" = "miniloong" ] || return 1 ;;
    trimui) [ "$param_device" = "trimui" ] || return 1 ;;
    muos|batocera|knulli|miyoo) [ "$param_device" = "$expected_device" ] || return 1 ;;
    generic) [ "$param_device" = "generic" ] || return 1 ;;
    official-untested) [ "$PAM_DEVICE_CLASS" = "official-untested" ] || return 1 ;;
    unsupported|unsupported-known) [ "$PAM_DEVICE_CLASS" = "unsupported-known" ] || return 1 ;;
    unknown) [ "$PAM_DEVICE_CLASS" = "unsupported-known" ] || return 1 ;;
  esac
  [ "$(pam_core_health)" = "healthy" ] || return 1
  version=$(pam_core_version); [ -n "$version" ] || return 1
  [ -f "$PAM_PORTMASTER_DIR/pugwash" ] || [ -f "$PAM_PORTMASTER_DIR/harbourmaster" ] || return 1
  if [ "$metadata_version" = "3" ]; then actual=$(pm_sha256_file "$PAM_FRONTEND_LAUNCHER" 2>/dev/null || true)
  else actual=$(pm_sha256_file "$SCRIPTS_DIR/PortMaster.sh" 2>/dev/null || true); fi
  [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$launcher_hash" | tr '[:upper:]' '[:lower:]')" ] || return 1
  pending_manifest_valid || return 1
  [ "$metadata_version" = "2" ] || pending_frontend_manifest_valid
}

remove_current_managed_core() {
  local item top failed=0
  for item in "$PAM_PORTMASTER_DIR"/* "$PAM_PORTMASTER_DIR"/.[!.]* "$PAM_PORTMASTER_DIR"/..?*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    top=$(basename "$item")
    case "$top" in
      libs|config|themes|logs|cache|log.txt|pugwash.txt|harbourmaster.txt|.appmanager-state|.appmanager-rollback) continue ;;
    esac
    rm -rf -- "$item" || failed=1
  done
  [ "$failed" = "0" ]
}

rollback_has_core() {
  local rollback="$1" item
  for item in "$rollback/core"/* "$rollback/core"/.[!.]* "$rollback/core"/..?*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    return 0
  done
  return 1
}

rollback_has_frontend() {
  local rollback="$1" item
  for item in "$rollback/frontend"/* "$rollback/frontend"/.[!.]* "$rollback/frontend"/..?*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    return 0
  done
  [ -e "$rollback/PortMaster.sh" ] || [ -L "$rollback/PortMaster.sh" ]
}

rollback_toplist_valid() {
  local rollback="$1" expected_count="$2" expected_hash="$3" actual count name
  case "$expected_count" in ''|*[!0-9]*) return 1 ;; esac
  case "$expected_hash" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
  [ "${#expected_hash}" = 64 ] && [ -f "$rollback/expected-tops.tsv" ] || return 1
  actual=$(pm_sha256_file "$rollback/expected-tops.tsv" 2>/dev/null || true)
  [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$expected_hash" | tr '[:upper:]' '[:lower:]')" ] || return 1
  count=0
  while IFS= read -r name; do
    case "$name" in ''|*/*|.|..) return 1 ;; esac
    count=$((count + 1))
  done < "$rollback/expected-tops.tsv"
  [ "$count" = "$expected_count" ]
}

rollback_frontend_list_valid() {
  local rollback="$1" expected_count="$2" expected_hash="$3" actual count=0 name
  case "$expected_count" in ''|*[!0-9]*) return 1 ;; esac
  case "$expected_hash" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
  [ "${#expected_hash}" = 64 ] && [ -f "$rollback/frontend-existing.tsv" ] || return 1
  actual=$(pm_sha256_file "$rollback/frontend-existing.tsv" 2>/dev/null || true)
  [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$expected_hash" | tr '[:upper:]' '[:lower:]')" ] || return 1
  while IFS= read -r name; do
    case "$name" in ''|*/*|.|..) return 1 ;; esac
    frontend_name_allowed "$name" || return 1
    count=$((count + 1))
  done < "$rollback/frontend-existing.tsv"
  [ "$count" = "$expected_count" ]
}

rollback_frontend_was_present() {
  grep -Fqx "$2" "$1/frontend-existing.tsv" 2>/dev/null
}

remove_current_frontend() {
  local name failed=0
  IFS=',' read -r -a frontend_items <<< "$PAM_FRONTEND_NAMES"
  for name in "${frontend_items[@]}"; do
    [ -n "$name" ] || continue
    rm -f -- "$PAM_FRONTEND_DIR/$name" || failed=1
  done
  [ "$failed" = "0" ]
}

restore_rollback() {
  local rollback="$1" sweep="$2" metadata_version="$3" had_launcher="$4" expected_count="$5" expected_hash="$6"
  local frontend_count="${7:--}" frontend_hash="${8:--}"
  local item top name backup live failed=0 restored=0 restore_count=0
  if [ "$expected_count" != "-" ]; then
    rollback_toplist_valid "$rollback" "$expected_count" "$expected_hash" || return 1
  fi
  if [ "$metadata_version" = "3" ]; then
    rollback_frontend_list_valid "$rollback" "$frontend_count" "$frontend_hash" || return 1
  fi
  if [ -e "$rollback/restoring" ]; then
    sweep=0
    restored=1
  fi
  if [ "$sweep" = "1" ]; then
    : > "$rollback/sweeping" || return 1
    remove_current_managed_core || failed=1
    if [ "$metadata_version" = "3" ]; then remove_current_frontend || failed=1
    else rm -f -- "$SCRIPTS_DIR/PortMaster.sh" || failed=1; fi
    [ "$failed" = "0" ] || return 1
    mv -f -- "$rollback/sweeping" "$rollback/restoring" || return 1
  fi
  if [ -d "$rollback/core" ]; then
    for item in "$rollback/core"/* "$rollback/core"/.[!.]* "$rollback/core"/..?*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      top=$(basename "$item")
      if [ -e "$PAM_PORTMASTER_DIR/$top" ] || [ -L "$PAM_PORTMASTER_DIR/$top" ]; then
        failed=1; continue
      fi
      mv -- "$item" "$PAM_PORTMASTER_DIR/" || { failed=1; continue; }
      restored=1
      restore_count=$((restore_count + 1))
      if [ "${PAM_TEST_FAIL_RESTORE_AFTER:-0}" = "$restore_count" ]; then return 1; fi
    done
  fi
  if [ "$metadata_version" = "3" ]; then
    IFS=',' read -r -a frontend_items <<< "$PAM_FRONTEND_NAMES"
    for name in "${frontend_items[@]}"; do
      [ -n "$name" ] || continue
      backup="$rollback/frontend/$name"; live="$PAM_FRONTEND_DIR/$name"
      if [ -e "$backup" ] || [ -L "$backup" ]; then
        if [ -e "$live" ] || [ -L "$live" ]; then failed=1
        else mv -- "$backup" "$live" || failed=1; restored=1; fi
      elif rollback_frontend_was_present "$rollback" "$name"; then
        [ -e "$live" ] || [ -L "$live" ] || failed=1
      elif [ "$sweep" = "1" ] || [ -e "$rollback/restoring" ]; then
        [ ! -e "$live" ] && [ ! -L "$live" ] || failed=1
      fi
    done
  elif [ "$had_launcher" = "1" ]; then
    if [ -f "$rollback/PortMaster.sh" ] || [ -L "$rollback/PortMaster.sh" ]; then
      if [ -e "$SCRIPTS_DIR/PortMaster.sh" ] || [ -L "$SCRIPTS_DIR/PortMaster.sh" ]; then failed=1
      else mv -- "$rollback/PortMaster.sh" "$SCRIPTS_DIR/PortMaster.sh" || failed=1; fi
    elif [ "$sweep" = "1" ] || { [ ! -f "$SCRIPTS_DIR/PortMaster.sh" ] && [ ! -L "$SCRIPTS_DIR/PortMaster.sh" ]; }; then
      failed=1
    fi
  elif [ -f "$rollback/PortMaster.sh" ] || [ -L "$rollback/PortMaster.sh" ]; then
    # Corrupt metadata must never make us discard an actual launcher backup.
    if [ -e "$SCRIPTS_DIR/PortMaster.sh" ] || [ -L "$SCRIPTS_DIR/PortMaster.sh" ]; then failed=1
    else mv -- "$rollback/PortMaster.sh" "$SCRIPTS_DIR/PortMaster.sh" || failed=1; restored=1; fi
  fi
  rollback_has_core "$rollback" && failed=1
  if [ "$metadata_version" = "3" ]; then rollback_has_frontend "$rollback" && failed=1; fi
  if [ "$expected_count" != "-" ]; then
    while IFS= read -r top; do
      [ -e "$PAM_PORTMASTER_DIR/$top" ] || [ -L "$PAM_PORTMASTER_DIR/$top" ] || failed=1
    done < "$rollback/expected-tops.tsv"
  fi
  [ "$failed" = "0" ] || return 1
  rm -rf -- "$rollback" || return 1
  [ "$restored" = "1" ] && return 0
  return 2
}

rollback_pending_core() {
  local file="$CONFDIR/pending-install.tsv" mode rollback had_launcher backup_count backup_hash metadata_version
  local frontend_count frontend_hash recorded_frontend_dir recorded_frontend_names
  local sweep=1 rc recorded_target recorded_scripts
  recorded_target=$(state_value "$file" target 2>/dev/null || true)
  recorded_scripts=$(state_value "$file" scripts 2>/dev/null || true)
  [ "$recorded_target" = "$PAM_PORTMASTER_DIR" ] && [ "$recorded_scripts" = "$SCRIPTS_DIR" ] || return 1
  metadata_version=$(state_value "$file" version 2>/dev/null || true)
  case "$metadata_version" in 2|3) ;; *) return 1 ;; esac
  mode=$(state_value "$file" mode 2>/dev/null || true)
  rollback=$(state_value "$file" rollback 2>/dev/null || true)
  had_launcher=$(state_value "$file" had_launcher 2>/dev/null || true)
  backup_count=$(state_value "$file" backup_top_count 2>/dev/null || true)
  backup_hash=$(state_value "$file" backup_top_sha256 2>/dev/null || true)
  if [ "$metadata_version" = "3" ]; then
    recorded_frontend_dir=$(state_value "$file" frontend_dir 2>/dev/null || true)
    recorded_frontend_names=$(state_value "$file" frontend_names 2>/dev/null || true)
    [ "$recorded_frontend_dir" = "$PAM_FRONTEND_DIR" ] && [ "$recorded_frontend_names" = "$PAM_FRONTEND_NAMES" ] || return 1
    frontend_count=$(state_value "$file" frontend_backup_count 2>/dev/null || true)
    frontend_hash=$(state_value "$file" frontend_backup_sha256 2>/dev/null || true)
  else
    frontend_count="-"; frontend_hash="-"
  fi
  case "$rollback" in
    "$PAM_PORTMASTER_DIR/.appmanager-rollback"|"$CONFDIR/rollback") ;;
    *) rollback="$PAM_PORTMASTER_DIR/.appmanager-rollback" ;;
  esac
  case "$had_launcher" in
    0|1) ;;
    *)
      if [ -f "$rollback/PortMaster.sh" ] || [ -L "$rollback/PortMaster.sh" ]; then had_launcher=1
      else had_launcher=0; fi
      ;;
  esac
  # The existence of backup content is safer evidence than damaged mode
  # metadata. It prevents a truncated update record from becoming first-install cleanup.
  if rollback_has_core "$rollback" || rollback_has_frontend "$rollback" || [ "$had_launcher" = "1" ]; then mode=update; else mode=install; fi
  restore_rollback "$rollback" "$sweep" "$metadata_version" "$had_launcher" "$backup_count" "$backup_hash" \
    "$frontend_count" "$frontend_hash"; rc=$?
  [ "$rc" = "1" ] && return 1
  rm -f -- "$CONFDIR/pending-install.tsv" "$CONFDIR/pending-manifest.tsv" \
    "$CONFDIR/pending-frontend-manifest.tsv" \
    "$CONFDIR/install-transaction.tsv" || return 1
  [ "$rc" = "0" ] && return 0
  return 2
}

recover_interrupted_transaction() {
  local file="$CONFDIR/install-transaction.tsv" version phase mode target scripts rollback had_launcher
  local backup_count backup_hash frontend_count frontend_hash frontend_dir frontend_names sweep rc
  version=$(state_value "$file" version) || return 1
  phase=$(state_value "$file" phase) || return 1
  mode=$(state_value "$file" mode) || return 1
  target=$(state_value "$file" target) || return 1
  scripts=$(state_value "$file" scripts) || return 1
  rollback=$(state_value "$file" rollback) || return 1
  had_launcher=$(state_value "$file" had_launcher) || return 1
  backup_count=$(state_value "$file" backup_top_count) || return 1
  backup_hash=$(state_value "$file" backup_top_sha256) || return 1
  case "$version" in 2|3) ;; *) return 1 ;; esac
  [ "$target" = "$PAM_PORTMASTER_DIR" ] && [ "$scripts" = "$SCRIPTS_DIR" ] || return 1
  if [ "$version" = "3" ]; then
    frontend_dir=$(state_value "$file" frontend_dir) || return 1
    frontend_names=$(state_value "$file" frontend_names) || return 1
    frontend_count=$(state_value "$file" frontend_backup_count) || return 1
    frontend_hash=$(state_value "$file" frontend_backup_sha256) || return 1
    [ "$frontend_dir" = "$PAM_FRONTEND_DIR" ] && [ "$frontend_names" = "$PAM_FRONTEND_NAMES" ] || return 1
  else
    frontend_count="-"; frontend_hash="-"
  fi
  [ "$rollback" = "$PAM_PORTMASTER_DIR/.appmanager-rollback" ] || return 1
  case "$mode:$had_launcher" in install:0|install:1|update:0|update:1) ;; *) return 1 ;; esac
  case "$phase" in
    prepared) sweep=0; backup_count="-"; backup_hash="-" ;;
    backed-up) sweep=1 ;;
    *) return 1 ;;
  esac
  restore_rollback "$rollback" "$sweep" "$version" "$had_launcher" "$backup_count" "$backup_hash" \
    "$frontend_count" "$frontend_hash"; rc=$?
  [ "$rc" = "1" ] && return 1
  rm -f -- "$file" "$CONFDIR/pending-install.tsv" "$CONFDIR/pending-manifest.tsv" \
    "$CONFDIR/pending-frontend-manifest.tsv" || return 1
  if [ "$rc" = "0" ] || { [ "$phase" = "prepared" ] && [ "$mode" = "update" ]; }; then return 0; fi
  return 2
}

validate_pending_install_inner() {
  local mode rc
  if [ ! -s "$CONFDIR/pending-install.tsv" ] && [ -s "$CONFDIR/install-transaction.tsv" ]; then
    validation_write checking "Recovering an interrupted PortMaster transaction"
    if recover_interrupted_transaction; then
      validation_write restored "The previous PortMaster environment was restored"
      return 1
    else
      rc=$?
      if [ "$rc" = "2" ]; then
        validation_write no-usable "The incomplete first installation was removed"
      else
        validation_write interrupted "Automatic recovery could not complete; recovery state was preserved"
      fi
      return 1
    fi
  fi
  [ -s "$CONFDIR/pending-install.tsv" ] || { validation_write none "No pending installation"; return 0; }
  validation_write checking "Validating installed PortMaster core"
  if [ "${PAM_TEST_INTERRUPT_VALIDATION:-0}" = "1" ]; then
    validation_write interrupted "Validation was interrupted before any state changed"
    return 75
  fi
  if pending_core_valid; then
    rm -f -- "$CONFDIR/pending-install.tsv" "$CONFDIR/pending-manifest.tsv" \
      "$CONFDIR/pending-frontend-manifest.tsv" \
      "$CONFDIR/install-transaction.tsv" || {
        validation_write interrupted "Validated core could not finalize its pending state"
        return 75
      }
    rm -rf -- "$PAM_PORTMASTER_DIR/.appmanager-rollback" "$CONFDIR/rollback"
    validation_write valid "PortMaster environment validated"
    return 0
  fi
  mode=$(pending_value mode)
  rollback_pending_core; rc=$?
  if [ "$rc" = "0" ]; then
    validation_write restored "The previous PortMaster environment was restored"
  elif [ "$rc" = "2" ]; then
    validation_write no-usable "The incomplete first installation was removed"
  else
    validation_write interrupted "Automatic rollback could not complete; recovery state was preserved"
  fi
  echo "$LOG_PREFIX pending PortMaster validation failed (mode=$mode)"
  return 1
}

validate_pending_install() {
  local lock="$CONFDIR/validation.lock" pid rc
  if ! mkdir "$lock" 2>/dev/null; then
    pid=$(sed -n '1p' "$lock/pid" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
    if [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null; then
      validation_write checking "Another validation process is still running"
      return 75
    fi
    rm -rf -- "$lock" || return 75
    mkdir "$lock" || return 75
  fi
  printf '%s\n' "$$" > "$lock/pid" || { rm -rf -- "$lock"; return 75; }
  validate_pending_install_inner; rc=$?
  rm -rf -- "$lock"
  return "$rc"
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

if [ "$INSTALL_PLAN_ONLY" = "1" ]; then
  install_plan="$CONFDIR/portmaster-install-plan.tsv"
  pam_write_install_plan "$install_plan" || exit 1
  cat "$install_plan"
  exit 0
fi

if [ "$CHECK_UPDATE_ONLY" = "1" ]; then
  pam_check_update
  rc=$?
  write_env
  exit "$rc"
fi

if [ "$RUNTIME_METADATA_ONLY" = "1" ]; then
  runtime_metadata_refresh 0
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
