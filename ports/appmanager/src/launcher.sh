#!/bin/bash
# PORTMASTER: jenny92-appmanager, APP Manager.sh
#
# APP Manager — PortMaster 端口管理器。
#
# The UI is self-contained: it starts from the launcher-adjacent jenny92-appmanager
# directory even when PortMaster is missing. Safety-critical filesystem
# mutations remain in this shell and are never performed directly by Lua.
#
# UI writes plan.txt and invokes this script's --apply-plan mode. The helper
# re-validates every path under $ESUDO, then the running LÖVE UI invalidates
# only the affected in-memory snapshots.

PORT_NAME="jenny92-appmanager"; LOG_PREFIX="[PAM]"
APPLY_ONLY=0
SIZE_ONLY=0
HEALTH_ONLY=0
CHECK_UPDATE_ONLY=0
FORCE_UPDATE_CHECK=0
VALIDATE_ONLY=0
RUNTIME_METADATA_ONLY=0
INSTALL_PLAN_ONLY=0
CONFIG_REFRESH_ONLY=0
ENV_ONLY=0
INVENTORY_ONLY=0
case "${1:-}" in
  --apply-plan) APPLY_ONLY=1 ;;
  --scan-sizes) SIZE_ONLY=1 ;;
  --health-check) HEALTH_ONLY=1 ;;
  --check-pm-update) CHECK_UPDATE_ONLY=1 ;;
  --check-pm-update-force) CHECK_UPDATE_ONLY=1; FORCE_UPDATE_CHECK=1 ;;
  --validate-pending) VALIDATE_ONLY=1 ;;
  --refresh-runtime-metadata) RUNTIME_METADATA_ONLY=1 ;;
  --write-install-plan) INSTALL_PLAN_ONLY=1 ;;
  --refresh-device-config) CONFIG_REFRESH_ONLY=1 ;;
  --write-env) ENV_ONLY=1 ;;
  --refresh-inventory) INVENTORY_ONLY=1 ;;
esac

# ── APP-owned bootstrap ──────────────────────────────────────────────────
# Resolve everything required to draw the repair UI before inspecting the
# managed PortMaster environment. MiniLoong may execute a temporary .port.sh,
# but PAM_SOURCE_DIR keeps the stable directory available to helper processes.
PAM_SCRIPT_DIR="$0"
case "$PAM_SCRIPT_DIR" in */*) PAM_SCRIPT_DIR=${PAM_SCRIPT_DIR%/*} ;; *) PAM_SCRIPT_DIR=. ;; esac
PAM_DIR="${PAM_SOURCE_DIR:-$(CDPATH= cd -- "$PAM_SCRIPT_DIR" && pwd)}"
PAM_LAUNCHER_SOURCE="$0"
PAM_APP_ROOT="$PAM_DIR/jenny92-appmanager"
[ -n "${PAM_APP_ROOT_OVERRIDE:-}" ] && PAM_APP_ROOT="$PAM_APP_ROOT_OVERRIDE"
PAM_RUNTIME_DIR="$PAM_APP_ROOT/runtime"
PAM_BIN_DIR="$PAM_APP_ROOT/bin"
PAM_SHARE_DIR="$PAM_APP_ROOT/share"
PAM_PORTKIT="${PAM_PORTKIT_BIN_OVERRIDE:-$PAM_BIN_DIR/portkit}"
PAM_APPMANAGER_CLI="${PAM_APPMANAGER_CLI_BIN_OVERRIDE:-$PAM_BIN_DIR/appmanager-cli}"
PAM_CONFIG_DIR="$PAM_APP_ROOT/config"
PAM_EARLY_STATE_DIR="${PAM_STATE_DIR_OVERRIDE:-$PAM_APP_ROOT/state}"
PAM_REMOTE_CONFIG_DIR="$PAM_EARLY_STATE_DIR/device-config"
PAM_REMOTE_CONFIG_ROOT="$PAM_REMOTE_CONFIG_DIR/config.json"

# portkit treats --target-override as a device path that is resolved under
# --root. PAM_PORTMASTER_DIR_OVERRIDE is the host path the shell uses directly;
# when a fixture root is active, strip it so portkit re-roots the override to
# the same host location instead of double-prefixing it.
PAM_NATIVE_TARGET_DEVICE="${PAM_PORTMASTER_DIR_OVERRIDE:-}"
if [ -n "${PAM_NATIVE_ROOT:-}" ] && [ -n "$PAM_NATIVE_TARGET_DEVICE" ]; then
  case "$PAM_NATIVE_TARGET_DEVICE" in
    "$PAM_NATIVE_ROOT"/*) PAM_NATIVE_TARGET_DEVICE="/${PAM_NATIVE_TARGET_DEVICE#"$PAM_NATIVE_ROOT"/}" ;;
    "$PAM_NATIVE_ROOT") PAM_NATIVE_TARGET_DEVICE="/" ;;
  esac
fi

#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/portable_tools.sh"
source "$KIT/launcher_artwork.sh"
#@KIT-END
if ! pam_tools_init; then
  printf '%s portable tool bootstrap failed: %s\n' "$LOG_PREFIX" "$PAM_UNAVAILABLE_TOOLS" \
    > "$PAM_APP_ROOT/log.txt" 2>/dev/null || true
  exit 78
fi
trap pam_tools_cleanup EXIT
portmaster_sync_launcher_artwork "$PAM_DIR" "$PAM_LAUNCHER_SOURCE"

PAM_PORTMASTER_DIR="${PAM_PORTMASTER_DIR_OVERRIDE:-}"
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
PAM_DEVICE_CLASS="unknown-path"
PAM_DEVICE_NAME="Unknown"
PAM_PORTMASTER_MANAGEMENT="app"
PAM_TARGET_CONFIRMED="0"
PAM_RELEASE_CHANNEL="official"
PAM_GAMEDIRS_DIR_DEFAULT=""
PAM_FRONTEND_KIND_DEFAULT="script-internal"
PAM_FRONTEND_DIR_DEFAULT=""
PAM_FRONTEND_NAMES_DEFAULT="PortMaster.sh"
PAM_FRONTEND_LAUNCHER_NAME="PortMaster.sh"
PAM_PYTHON_RUNTIME_FALLBACK="0"
PAM_SCRIPTS_DIR_DEFAULT=""

pam_apply_native_profile() {
  local result="${TMPDIR:-/tmp}/pam-profile.$$" schema="" key value native_launcher
  native_launcher="${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_LAUNCHER_SOURCE}"
  case "$native_launcher" in /*) ;; *) native_launcher="$PAM_DIR/$(basename "$native_launcher")" ;; esac
  set -- resolve --config-dir "$PAM_CONFIG_DIR" --launcher "$native_launcher" --format tsv
  [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
  if [ -s "$PAM_REMOTE_CONFIG_ROOT" ]; then
    set -- "$@" --remote-config "$PAM_REMOTE_CONFIG_ROOT" --remote-config-dir "$PAM_REMOTE_CONFIG_DIR"
  fi
  [ -z "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || set -- "$@" --target-override "$PAM_NATIVE_TARGET_DEVICE"
  "$PAM_PORTKIT" "$@" > "$result" 2>/dev/null || { rm -f -- "$result"; return 1; }
  while IFS=$'\t' read -r key value; do
    case "$value" in *$'\t'*|*$'\r'*|*$'\n'*) rm -f -- "$result"; return 1 ;; esac
    case "$key" in
      schema) schema="$value" ;;
      platform_id) param_device="$value" ;;
      platform_display_name) CFW_NAME="$value"; PAM_DEVICE_NAME="$value" ;;
      device_class) PAM_DEVICE_CLASS="$value" ;;
      target_confirmed) [ "$value" = "true" ] && PAM_TARGET_CONFIRMED=1 || PAM_TARGET_CONFIRMED=0 ;;
      source_route) PAM_RELEASE_CHANNEL="$value" ;;
      frontend_management) PAM_PORTMASTER_MANAGEMENT="$value" ;;
      frontend_kind) PAM_FRONTEND_KIND_DEFAULT="$value" ;;
      frontend_names) [ -n "$value" ] && PAM_FRONTEND_NAMES_DEFAULT="$value" || PAM_FRONTEND_NAMES_DEFAULT="-" ;;
      frontend_primary) PAM_FRONTEND_LAUNCHER_NAME="$value" ;;
      scripts) PAM_SCRIPTS_DIR_DEFAULT="$value" ;;
      launcher_directory) directory="$value" ;;
      game_data) PAM_GAMEDIRS_DIR_DEFAULT="$value" ;;
      portmaster_core) PAM_PORTMASTER_DIR="$value" ;;
      frontend) PAM_FRONTEND_DIR_DEFAULT="$value" ;;
      images) PAM_IMAGES_DIR_DEFAULT="$value" ;;
      python_mode) [ "$value" = "runtime_mount" ] && PAM_PYTHON_RUNTIME_FALLBACK=1 || PAM_PYTHON_RUNTIME_FALLBACK=0 ;;
      display_width)
        case "$value" in ''|*[!0-9]*) rm -f -- "$result"; return 1 ;; *) DISPLAY_WIDTH="$value" ;; esac
        ;;
      display_height)
        case "$value" in ''|*[!0-9]*) rm -f -- "$result"; return 1 ;; *) DISPLAY_HEIGHT="$value" ;; esac
        ;;
      analog_sticks)
        case "$value" in ''|*[!0-9]*) rm -f -- "$result"; return 1 ;; *) ANALOGSTICKS="$value" ;; esac
        ;;
      capability_install_portmaster) PAM_CAPABILITY_INSTALL_PORTMASTER="$value" ;;
      capability_update_portmaster) PAM_CAPABILITY_UPDATE_PORTMASTER="$value" ;;
      capability_repair_runtimes) PAM_CAPABILITY_REPAIR_RUNTIMES="$value" ;;
      capability_manage_portmaster) PAM_CAPABILITY_MANAGE_PORTMASTER="$value" ;;
      capability_manage_ports) PAM_CAPABILITY_MANAGE_PORTS="$value" ;;
      capability_trash) PAM_CAPABILITY_TRASH="$value" ;;
      capability_leftovers) PAM_CAPABILITY_LEFTOVERS="$value" ;;
      capability_cleanup_appledouble) PAM_CAPABILITY_CLEANUP_APPLEDOUBLE="$value" ;;
      capability_manage_artwork) PAM_CAPABILITY_MANAGE_ARTWORK="$value" ;;
      capability_manage_frontend) PAM_CAPABILITY_MANAGE_FRONTEND="$value" ;;
      capability_manage_images) PAM_CAPABILITY_MANAGE_IMAGES="$value" ;;
      source_manifest_url) PAM_RELEASE_MANIFEST_URL="$value" ;;
      source_archive_url) PAM_RELEASE_ARCHIVE_URL="$value" ;;
      source_archive_name) PAM_RELEASE_ARCHIVE_NAME="$value" ;;
      source_install_allowed) PAM_RELEASE_INSTALL_ALLOWED="$value" ;;
      health_contract) PAM_HEALTH_CONTRACT="$value" ;;
      health_required) PAM_HEALTH_REQUIRED="$value" ;;
    esac
  done < "$result"
  rm -f -- "$result"
  [ "$schema" = "1" ] && [ -n "${param_device:-}" ] || return 1
  if [ "$PAM_TARGET_CONFIRMED" != "1" ]; then PAM_PORTMASTER_DIR=""; fi
}

PAM_NATIVE_PROFILE_ACTIVE=0
if [ ! -x "$PAM_PORTKIT" ]; then
  echo "$LOG_PREFIX native device helper is missing; reinstall or repair APP Manager" >&2
  exit 78
fi
if ! pam_apply_native_profile; then
  echo "$LOG_PREFIX native device profile failed; reinstall or repair APP Manager" >&2
  exit 78
fi
PAM_NATIVE_PROFILE_ACTIVE=1
[ -z "${PAM_DIRECTORY_OVERRIDE:-}" ] || directory="$PAM_DIRECTORY_OVERRIDE"

# PortMaster's aarch64 LÖVE package normally relies on the firmware for Theora.
# ROCKNIX-family images may omit it, so use the adjacent compatibility copy
# only when this system family does not already provide the SONAME. Other
# devices keep resolving their firmware library and are never shadowed by it.
PAM_LOVE_LIBRARY_PATH="$PAM_RUNTIME_DIR/libs.aarch64"
case "$param_device" in
  rocknix|jelos|unofficialos)
    PAM_THEORA_COMPAT_DIR="$PAM_RUNTIME_DIR/compat.rocknix.aarch64"
    PAM_SYSTEM_THEORA=""
    for PAM_LIBRARY_DIR in /lib /lib64 /usr/lib /usr/lib64 /lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu; do
      if [ -e "$PAM_LIBRARY_DIR/libtheoradec.so.1" ]; then PAM_SYSTEM_THEORA=1; break; fi
    done
    if [ -z "$PAM_SYSTEM_THEORA" ] && [ -f "$PAM_THEORA_COMPAT_DIR/libtheoradec.so.1" ]; then
      PAM_LOVE_LIBRARY_PATH="$PAM_THEORA_COMPAT_DIR:$PAM_LOVE_LIBRARY_PATH"
    fi
    ;;
esac

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
#   ROCKNIX      gamedirs=/storage/roms/ports        scripts=本启动器所在目录
# 所以脚本目录不去查任何配置, 直接认最强的事实: 本脚本自己就躺在脚本目录里。
SCRIPTS_DIR="${PAM_SCRIPTS_DIR_OVERRIDE:-${PAM_SCRIPTS_DIR_DEFAULT:-$PAM_DIR}}"
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

# Use the same shared device adapter as every launcher. This keeps scanning,
# uninstall, Trash restore and launch-time artwork synchronization on one path.
portmaster_resolve_launcher_image_dir "$SCRIPTS_DIR"
IMAGES_DIR="${PAM_IMAGES_DIR_DEFAULT:-$PORTMASTER_LAUNCHER_IMAGE_DIR}"

# A same-stem image beside its SH belongs to the selected Port on every device.
# A separate frontend image folder is managed only when the shared adapter has
# positively identified a tested MiniLoong or TrimUI layout.
pam_is_image_name() {
  case "$1" in
    *.png|*.PNG|*.jpg|*.JPG|*.jpeg|*.JPEG|*.webp|*.WEBP) return 0 ;;
    *) return 1 ;;
  esac
}
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
RUNTIME_METADATA_JSON="$CONFDIR/ports.json"
DEVICE_CONFIG_DIR="$CONFDIR/device-config"
DEVICE_CONFIG_FILE="$DEVICE_CONFIG_DIR/config.json"
CONFIG_REFRESH_RESULT="$CONFDIR/config-refresh.tsv"
CONFIG_REFRESH_SESSION="$CONFDIR/config-refresh-session.tsv"
INVENTORY_FILE="$CONFDIR/inventory.json"

# PID values can be reused after a reboot. A marker is live only when /proc
# still identifies our helper script and the exact background operation.
pam_helper_pid_alive() {
  local pid="$1" mode="$2" cmdline
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  cmdline="${PAM_PROC_ROOT:-/proc}/$pid/cmdline"
  [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null && [ -r "$cmdline" ] || return 1
  tr '\000' '\n' < "$cmdline" 2>/dev/null | awk -v helper="$APPLY_HELPER" -v mode="$mode" '
    $0 == helper { have_helper=1 }
    $0 == mode { have_mode=1 }
    END { exit !(have_helper && have_mode) }
  '
}

# Directory creation is the lock acquisition primitive. The owner record is
# written atomically, and cleanup removes a lock only when its random token is
# still ours. A contender waits out the tiny mkdir-to-owner publication window
# instead of treating a not-yet-published lock as stale.
pam_lock_acquire() {
  local lock="$1" mode="$2" attempt=0 owner snapshot current pid token
  token="$$-$(date +%s 2>/dev/null || printf 0)-${RANDOM:-0}"
  owner="$lock/owner.tsv"
  PAM_LOCK_TOKEN=""
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    if mkdir "$lock" 2>/dev/null; then
      {
        printf 'version\t1\n'
        printf 'token\t%s\n' "$token"
        printf 'pid\t%s\n' "$$"
        printf 'mode\t%s\n' "$mode"
      } > "$lock/owner.tmp.$$" && mv -f -- "$lock/owner.tmp.$$" "$owner" || {
        rm -f -- "$lock/owner.tmp.$$"
        rmdir "$lock" 2>/dev/null || true
        return 75
      }
      PAM_LOCK_TOKEN="$token"
      return 0
    fi

    snapshot=$(sed -n '1,8p' "$owner" 2>/dev/null || true)
    if [ -z "$snapshot" ]; then
      sleep 1
      [ -s "$owner" ] && continue
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    pid=$(printf '%s\n' "$snapshot" | awk -F '\t' '$1 == "pid" {print $2; exit}')
    if pam_helper_pid_alive "$pid" "$mode"; then return 1; fi
    [ ! -L "$owner" ] || return 75
    current=$(sed -n '1,8p' "$owner" 2>/dev/null || true)
    [ "$current" = "$snapshot" ] || continue
    rm -f -- "$owner" || return 75
    rmdir "$lock" 2>/dev/null || true
  done
  return 1
}

pam_lock_release() {
  local lock="$1" token="$2" owner="$1/owner.tsv" current
  [ -n "$token" ] && [ ! -L "$owner" ] || return 1
  current=$(awk -F '\t' '$1 == "token" {print $2; exit}' "$owner" 2>/dev/null || true)
  [ "$current" = "$token" ] || return 1
  rm -f -- "$owner" || return 1
  rmdir "$lock" 2>/dev/null
}

#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
PORT_SRC="$(cd "$(dirname "$0")" && pwd)"
source "$PORT_SRC/appmanager_sources.sh"
#@KIT-END

# A native profile is a literal TSV contract. Capability fields are explicit
# rather than dynamically assigned so a remote configuration cannot turn an
# arbitrary TSV key into a shell variable name.
pam_bool_value() {
  case "${1:-}" in true|1) printf true ;; false|0) printf false ;; *) return 1 ;; esac
}

pam_capability_enabled() {
  case "${1:-}" in true|1) return 0 ;; *) return 1 ;; esac
}

pam_json_bool() {
  if pam_capability_enabled "${1:-}"; then printf true; else printf false; fi
}

pam_validate_capabilities() {
  for PAM_CAPABILITY_VALUE in \
    "${PAM_CAPABILITY_INSTALL_PORTMASTER:-}" "${PAM_CAPABILITY_UPDATE_PORTMASTER:-}" \
    "${PAM_CAPABILITY_REPAIR_RUNTIMES:-}" "${PAM_CAPABILITY_MANAGE_PORTMASTER:-}" \
    "${PAM_CAPABILITY_MANAGE_PORTS:-}" "${PAM_CAPABILITY_TRASH:-}" "${PAM_CAPABILITY_LEFTOVERS:-}" \
    "${PAM_CAPABILITY_CLEANUP_APPLEDOUBLE:-}" "${PAM_CAPABILITY_MANAGE_ARTWORK:-}" \
    "${PAM_CAPABILITY_MANAGE_FRONTEND:-}" "${PAM_CAPABILITY_MANAGE_IMAGES:-}" \
    "${PAM_RELEASE_INSTALL_ALLOWED:-}"; do
    pam_bool_value "$PAM_CAPABILITY_VALUE" >/dev/null || return 1
  done
}

pam_release_manifest_url() {
  if [ -n "${PAM_RELEASE_MANIFEST_URL:-}" ]; then
    printf '%s\n' "$PAM_RELEASE_MANIFEST_URL"
  elif [ "$PAM_RELEASE_CHANNEL" = "miniloong-custom" ]; then
    printf '%s\n' "$PAM_CUSTOM_VERSION_URL"
  else
    printf '%s\n' "$PAM_OFFICIAL_VERSION_URL"
  fi
}

pam_release_archive_name() {
  local name="${PAM_RELEASE_ARCHIVE_NAME:-PortMaster.zip}"
  case "$name" in *.zip) ;; *) return 1 ;; esac
  case "$name" in *[!A-Za-z0-9._+-]*|.|..) return 1 ;; esac
  printf '%s\n' "$name"
}

pam_release_manifest_valid() {
  case "$1" in https://github.com/*/*/releases/latest/download/version.json) return 0 ;; esac
  return 1
}

pam_release_route_allowed() {
  pam_capability_enabled "$PAM_CAPABILITY_INSTALL_PORTMASTER" &&
    pam_capability_enabled "$PAM_RELEASE_INSTALL_ALLOWED" &&
    pam_release_manifest_valid "$(pam_release_manifest_url)" &&
    pam_release_archive_name >/dev/null
}

pam_update_allowed() {
  pam_capability_enabled "$PAM_CAPABILITY_UPDATE_PORTMASTER" && pam_release_route_allowed
}

pam_runtime_repair_allowed() {
  pam_capability_enabled "$PAM_CAPABILITY_REPAIR_RUNTIMES"
}

pam_validate_capabilities || {
  echo "$LOG_PREFIX invalid native capability value; disabling PortMaster mutations" >&2
  PAM_CAPABILITY_INSTALL_PORTMASTER=false
  PAM_CAPABILITY_UPDATE_PORTMASTER=false
  PAM_CAPABILITY_REPAIR_RUNTIMES=false
  PAM_RELEASE_INSTALL_ALLOWED=false
}

mkdir -p "$PAM_APP_ROOT" "$CONFDIR" "$TRASH_DIR"
PORTMASTER_ACTIVE=0

# A killed UI must not make an in-flight background repair invisible. Remove
# only demonstrably stale markers; a live helper keeps the next APP instance
# blocked until it finishes and publishes pending-validation state.
if [ -s "$PORTMASTER_ACTIVE_FILE" ]; then
  active_pid=$(awk -F '\t' '$1 == "pid" {print $2; exit}' "$PORTMASTER_ACTIVE_FILE" 2>/dev/null || true)
  if ! pam_helper_pid_alive "$active_pid" --apply-plan; then
    rm -f -- "$PORTMASTER_ACTIVE_FILE"
  else
    PORTMASTER_ACTIVE=1
  fi
fi
cd "$PAM_APP_ROOT" || exit 1
if [ "$HEALTH_ONLY" = "1" ] || [ "$INSTALL_PLAN_ONLY" = "1" ]; then
  :
elif [ "$APPLY_ONLY" = "1" ] || [ "$SIZE_ONLY" = "1" ] || [ "$CHECK_UPDATE_ONLY" = "1" ] ||
     [ "$VALIDATE_ONLY" = "1" ] || [ "$RUNTIME_METADATA_ONLY" = "1" ] || [ "$CONFIG_REFRESH_ONLY" = "1" ] ||
     [ "$ENV_ONLY" = "1" ] || [ "$INVENTORY_ONLY" = "1" ]; then
  exec >> "$GAMEDIR/log.txt" 2>&1
else
  exec > "$GAMEDIR/log.txt" 2>&1
fi

if [ "$APPLY_ONLY" != "1" ] && [ "$SIZE_ONLY" != "1" ] && [ "$CHECK_UPDATE_ONLY" != "1" ] &&
   [ "$VALIDATE_ONLY" != "1" ] && [ "$RUNTIME_METADATA_ONLY" != "1" ] && [ "$INSTALL_PLAN_ONLY" != "1" ] &&
   [ "$CONFIG_REFRESH_ONLY" != "1" ] && [ "$ENV_ONLY" != "1" ] && [ "$INVENTORY_ONLY" != "1" ]; then
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
[ "$HEALTH_ONLY" = "1" ] || [ "$INSTALL_PLAN_ONLY" = "1" ] ||
  echo "$LOG_PREFIX tools=$PAM_TOOL_PROVIDER${PAM_TOOL_PROBE_FAILURE:+ system_probe=$PAM_TOOL_PROBE_FAILURE}"

pam_miniloong_fonts_complete() {
  local font size
  for font in HK JP KR SC TC; do
    [ -f "$PAM_PORTMASTER_DIR/pylibs/resources/NotoSans${font}-Regular.ttf" ] || return 1
    size=$(wc -c < "$PAM_PORTMASTER_DIR/pylibs/resources/NotoSans${font}-Regular.ttf" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    [ "$size" -gt 1048576 ] || return 1
  done
}

pam_zip_readable() {
  [ -x "$PAM_PORTKIT" ] && "$PAM_PORTKIT" file zip-readable --input "$1" >/dev/null 2>&1
}

pam_native_health_status() {
  local result="${TMPDIR:-/tmp}/pam-health.$$" key value schema="" contract="" status="" native_launcher
  [ "$PAM_NATIVE_PROFILE_ACTIVE" = 1 ] || return 1
  native_launcher="${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_LAUNCHER_SOURCE}"
  case "$native_launcher" in /*) ;; *) native_launcher="$PAM_DIR/$(basename "$native_launcher")" ;; esac
  set -- health --config-dir "$PAM_CONFIG_DIR" --launcher "$native_launcher" --format tsv
  [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
  [ -s "$DEVICE_CONFIG_FILE" ] && set -- "$@" --remote-config "$DEVICE_CONFIG_FILE" --remote-config-dir "$DEVICE_CONFIG_DIR"
  [ -z "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || set -- "$@" --target-override "$PAM_NATIVE_TARGET_DEVICE"
  "$PAM_PORTKIT" "$@" > "$result" 2>/dev/null || { rm -f -- "$result"; return 1; }
  while IFS=$'\t' read -r key value; do
    case "$value" in *$'\t'*|*$'\r'*|*$'\n'*) rm -f -- "$result"; return 1 ;; esac
    case "$key" in schema) schema="$value" ;; health_contract) contract="$value" ;; health_status) status="$value" ;; esac
  done < "$result"
  rm -f -- "$result"
  [ "$schema" = 1 ] && [ "$contract" = "${PAM_HEALTH_CONTRACT:-portkit.health.v1}" ] || return 1
  case "$status" in healthy|damaged|unresolved) printf '%s\n' "$status" ;; *) return 1 ;; esac
}

pam_core_health() {
  local native_health
  [ -d "$PAM_PORTMASTER_DIR" ] || { printf missing; return; }
  native_health=$(pam_native_health_status 2>/dev/null || true)
  case "$native_health" in
    damaged) printf damaged; return ;;
    unresolved) printf missing; return ;;
    healthy)
      # Native health owns config-derived filesystem and Python requirements.
      # Keep only archive structure and the downstream MiniLoong font guard as
      # additional checks for release damage discovered on real devices.
      if [ -f "$PAM_PORTMASTER_DIR/pylibs.zip" ]; then
        pam_zip_readable "$PAM_PORTMASTER_DIR/pylibs.zip" || {
            printf damaged; return;
          }
      fi
      if [ "$PAM_RELEASE_CHANNEL" = "miniloong-custom" ] && [ -d "$PAM_PORTMASTER_DIR/pylibs" ]; then
        pam_miniloong_fonts_complete ||
          [ -s "$PAM_PORTMASTER_DIR/pylibs/resources/NotoSans.tar.xz" ] || {
            printf damaged; return;
          }
      fi
      printf healthy; return
      ;;
  esac
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
    core-internal)
      [ -x "$PAM_PORTMASTER_DIR/PortMaster.sh" ] || { printf damaged; return; }
      ;;
    script-internal)
      [ -x "$PAM_PORTMASTER_DIR/PortMaster.sh" ] || { printf damaged; return; }
      [ -x "$PAM_FRONTEND_LAUNCHER" ] || { printf damaged; return; }
      ;;
    *) printf damaged; return ;;
  esac
  if [ -f "$PAM_PORTMASTER_DIR/pylibs.zip" ]; then
    # Full CRC/decompression validation is already performed by the install
    # transaction's hash manifest. Normal startup only needs a readable,
    # non-empty central directory; re-inflating the whole archive on every
    # launch is disproportionately slow on low-end SD cards.
    pam_zip_readable "$PAM_PORTMASTER_DIR/pylibs.zip" || {
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
  local free scan_script_images=false update_checked=0 update_status="unknown" update_latest="" env_tmp="$CONFDIR/env.json.tmp.$$"
  if [ -z "${PAM_CORE_HEALTH_CACHE+x}" ]; then PAM_CORE_HEALTH_CACHE=$(pam_core_health); fi
  # MiniLoong may expose launcher artwork beside the SH as well as under
  # ports/images. TrimUI was tested to consume only Imgs/PORTS, so treating a
  # same-directory PNG there as managed artwork would be misleading.
  [ "$param_device" = "miniloong" ] && scan_script_images=true
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
  "scan_script_images": $scan_script_images,
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
  "inventory_file": "$(json_escape "$INVENTORY_FILE")",
  "config_refresh_result": "$(json_escape "$CONFIG_REFRESH_RESULT")",
  "app_root": "$(json_escape "$PAM_APP_ROOT")",
  "portmaster_health": "$(json_escape "$PAM_CORE_HEALTH_CACHE")",
  "portmaster_version": "$(json_escape "$(pam_core_version)")",
  "portmaster_target": "$(json_escape "$PAM_PORTMASTER_DIR")",
  "portmaster_release_channel": "$(json_escape "$PAM_RELEASE_CHANNEL")",
  "portmaster_release_manifest_url": "$(json_escape "$(pam_release_manifest_url)")",
  "portmaster_release_archive_url": "$(json_escape "${PAM_RELEASE_ARCHIVE_URL:-}")",
  "portmaster_release_archive_name": "$(json_escape "$(pam_release_archive_name 2>/dev/null || true)")",
  "portmaster_release_install_allowed": $(pam_json_bool "$PAM_RELEASE_INSTALL_ALLOWED"),
  "portmaster_management": "$(json_escape "$PAM_PORTMASTER_MANAGEMENT")",
  "capability_install_portmaster": $(pam_json_bool "$PAM_CAPABILITY_INSTALL_PORTMASTER"),
  "capability_update_portmaster": $(pam_json_bool "$PAM_CAPABILITY_UPDATE_PORTMASTER"),
  "capability_repair_runtimes": $(pam_json_bool "$PAM_CAPABILITY_REPAIR_RUNTIMES"),
  "capability_manage_portmaster": $(pam_json_bool "$PAM_CAPABILITY_MANAGE_PORTMASTER"),
  "capability_manage_ports": $(pam_json_bool "$PAM_CAPABILITY_MANAGE_PORTS"),
  "capability_trash": $(pam_json_bool "$PAM_CAPABILITY_TRASH"),
  "capability_leftovers": $(pam_json_bool "$PAM_CAPABILITY_LEFTOVERS"),
  "capability_cleanup_appledouble": $(pam_json_bool "$PAM_CAPABILITY_CLEANUP_APPLEDOUBLE"),
  "capability_manage_artwork": $(pam_json_bool "$PAM_CAPABILITY_MANAGE_ARTWORK"),
  "capability_manage_frontend": $(pam_json_bool "$PAM_CAPABILITY_MANAGE_FRONTEND"),
  "capability_manage_images": $(pam_json_bool "$PAM_CAPABILITY_MANAGE_IMAGES"),
  "health_contract": "$(json_escape "${PAM_HEALTH_CONTRACT:-}")",
  "health_required": "$(json_escape "${PAM_HEALTH_REQUIRED:-}")",
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
  "ignore_dirs": ["PortMaster", "autoinstall", "images", "$(json_escape "$PORT_NAME")"],
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
size_cache_record_move() {
  local source="$1" target="$2"
  [ -f "$SIZE_FILE" ] && [ -n "${SIZE_MUTATIONS:-}" ] || return 0
  case "$source$target" in *$'\t'*|*$'\r'*|*$'\n'*) return 0 ;; esac
  printf 'M\t%s\t%s\n' "$source" "$target" >> "$SIZE_MUTATIONS"
}

size_cache_record_delete() {
  local source="$1"
  [ -f "$SIZE_FILE" ] && [ -n "${SIZE_MUTATIONS:-}" ] || return 0
  case "$source" in *$'\t'*|*$'\r'*|*$'\n'*) return 0 ;; esac
  printf 'D\t%s\n' "$source" >> "$SIZE_MUTATIONS"
}

size_cache_apply_mutations() {
  local tmp missing target bytes
  [ -f "$SIZE_FILE" ] && [ -s "${SIZE_MUTATIONS:-}" ] || return 0
  tmp="${SIZE_FILE}.tmp.$$"
  missing="${SIZE_FILE}.missing.$$"
  : > "$missing" || return 1
  LC_ALL=C awk -F '\t' -v missing="$missing" '
    function dropped(path, i, root) {
      for (i=1; i<=drop_count; i++) {
        root=drops[i]
        if (path==root || index(path, root "/")==1) return 1
      }
      return 0
    }
    NR==FNR {
      if ($1=="M") {
        move[$2]=$3; order[++count]=$2
      } else if ($1=="D") drops[++drop_count]=$2
      next
    }
    {
      path=$0; sub(/^[^\t]*\t/, "", path)
      if (path in move) {
        print $1 "\t" move[path]
        emitted[path]=1
      } else if (!dropped(path)) print $0
    }
    END {
      for (i=1; i<=count; i++) {
        path=order[i]
        if (!emitted[path]) {
          print move[path] > missing
          emitted[path]=1
        }
      }
    }
  ' "$SIZE_MUTATIONS" "$SIZE_FILE" > "$tmp" || {
    rm -f -- "$tmp" "$missing"
    return 1
  }
  while IFS= read -r target; do
    bytes=$(size_bytes "$target")
    case "$bytes" in ''|*[!0-9]*) continue ;; esac
    printf '%s\t%s\n' "$bytes" "$target" >> "$tmp"
  done < "$missing"
  mv -f -- "$tmp" "$SIZE_FILE"
  rm -f -- "$missing"
}

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
    images|script-images)
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
    size_cache_record_move "$item" "$target/$base"
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
  if { [ "$bucket" = "scripts" ] || [ "$bucket" = "script-images" ] ||
       [ "$bucket" = "images" ] || [ "$bucket" = "data" ]; } &&
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
    script-images) target="$SCRIPTS_DIR" ;;
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
      scripts|script-images|images|data)
        printf 'FAIL\toperation\n' >> "$RESULT_FILE"
        echo "$LOG_PREFIX rejected trash bucket delete: $source"
        return
        ;;
    esac
  fi
  if { [ "$bucket" = "scripts" ] || [ "$bucket" = "script-images" ] ||
       [ "$bucket" = "images" ] || [ "$bucket" = "data" ]; } &&
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
    size_cache_record_delete "$source"
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

runtime_has_magic() {
  [ -f "$1" ] && [ "$(LC_ALL=C head -c 4 "$1" 2>/dev/null)" = "hsqs" ]
}

runtime_metadata_parse() {
  local source="$1" output="$2"
  [ -f "$source" ] && [ ! -L "$source" ] && [ -x "$PAM_APPMANAGER_CLI" ] || return 1
  rm -f -- "$output"
  "$PAM_APPMANAGER_CLI" parse-runtime-metadata --metadata "$source" --format tsv > "$output" || {
    rm -f -- "$output"
    return 1
  }
  awk -F '\t' '
    NF != 5 || $1 !~ /^[A-Za-z0-9._+-]+$/ ||
    $2 !~ /^(aarch64|armhf|x86_64)$/ || $3 !~ /^[0-9]+$/ ||
    $4 !~ /^[0-9a-f]+$/ || length($4) != 32 ||
    $5 !~ /^https:\/\/github.com\/PortsMaster\/PortMaster-New\/releases\/download\/[^\/]+\/[A-Za-z0-9._+-]+\.squashfs$/ ||
    seen[$1 SUBSEP $2]++ { exit 1 }
  ' "$output"
}

pam_stable_metadata_parse() {
  local source="$1" output="$2"
  [ -f "$source" ] && [ ! -L "$source" ] && [ -x "$PAM_APPMANAGER_CLI" ] || return 1
  rm -f -- "$output"
  "$PAM_APPMANAGER_CLI" parse-stable-manifest --manifest "$source" --format tsv > "$output" || {
    rm -f -- "$output"
    return 1
  }
  awk -F '\t' 'NF != 3 || $1 == "" || $2 == "" || $3 == "" { exit 1 }' "$output"
}

runtime_metadata_refresh() {
  local force="${1:-0}" now mtime root json_tmp metadata_tmp
  if [ "$force" != "1" ] && [ -s "$RUNTIME_METADATA" ] && [ -s "$RUNTIME_METADATA_JSON" ]; then
    now=$(date +%s 2>/dev/null || printf 0)
    mtime=$(pam_cache_mtime "$RUNTIME_METADATA")
    case "$now:$mtime" in *[!0-9:]*|:) mtime=0 ;; esac
    [ "$mtime" -le 0 ] || [ $((now - mtime)) -ge 86400 ] || return 0
  fi
  root="$CONFDIR/runtime-metadata.$$"
  rm -rf -- "$root"; mkdir -p "$root" || return 1
  json_tmp="$root/ports.json"; metadata_tmp="$root/runtime-metadata.tsv"
  if "$PAM_APPMANAGER_CLI" fetch-runtime-metadata \
       --source "$RUNTIME_METADATA_URL" --output "$json_tmp" >/dev/null 2>> "$PAM_APP_ROOT/log.txt" &&
     runtime_metadata_parse "$json_tmp" "$metadata_tmp"; then
    mv -f -- "$json_tmp" "$RUNTIME_METADATA_JSON" &&
      mv -f -- "$metadata_tmp" "$RUNTIME_METADATA"
  else
    rm -rf -- "$root"
    [ "$force" != "1" ] && [ -s "$RUNTIME_METADATA" ] && [ -s "$RUNTIME_METADATA_JSON" ]
    return
  fi
  rm -rf -- "$root"
  return 0
}

pam_repair_runtime_native() {
  local runtime="$1" output="$CONFDIR/runtime-native-result.$$"
  [ "$PAM_NATIVE_PROFILE_ACTIVE" = 1 ] && [ -x "$PAM_APPMANAGER_CLI" ] || return 1
  [ -s "$RUNTIME_METADATA_JSON" ] || return 1
  rm -f -- "$output" "$CANCEL_FILE"
  if "$PAM_APPMANAGER_CLI" repair-runtimes \
       --metadata "$RUNTIME_METADATA_JSON" --runtime "$runtime" --arch "$(runtime_arch)" \
       --libs-root "$LIBS_DIR" --progress "$PROGRESS_FILE" --cancel-file "$CANCEL_FILE" \
       > "$output" 2>> "$PAM_APP_ROOT/log.txt"; then
    rm -f -- "$output"
    return 0
  fi
  rm -f -- "$output"
  return 1
}

pam_repair_plan_runtimes_native() {
  local kind runtime output="$CONFDIR/runtime-native-result.$$" count=0
  [ "$PAM_NATIVE_PROFILE_ACTIVE" = 1 ] && [ -x "$PAM_APPMANAGER_CLI" ] || return 1
  [ -s "$RUNTIME_METADATA_JSON" ] || return 1
  set -- repair-runtimes --metadata "$RUNTIME_METADATA_JSON" --arch "$(runtime_arch)" \
    --libs-root "$LIBS_DIR" --progress "$PROGRESS_FILE" --cancel-file "$CANCEL_FILE"
  while IFS=$'\t' read -r kind runtime; do
    [ "$kind" = "INSTALL_RUNTIME" ] || continue
    set -- "$@" --runtime "$runtime"
    count=$((count + 1))
  done < "$PLAN_FILE"
  [ "$count" -gt 0 ] || return 1
  rm -f -- "$output" "$CANCEL_FILE"
  if "$PAM_APPMANAGER_CLI" "$@" > "$output" 2>> "$PAM_APP_ROOT/log.txt"; then
    while IFS=$'\t' read -r kind runtime; do
      [ "$kind" = "INSTALL_RUNTIME" ] || continue
      printf 'OK\truntime\t%s\tnative\n' "$runtime" >> "$RESULT_FILE"
    done < "$PLAN_FILE"
    rm -f -- "$output"
    return 0
  fi
  while IFS=$'\t' read -r kind runtime; do
    [ "$kind" = "INSTALL_RUNTIME" ] || continue
    # A batch commits each verified Runtime independently. If a later item
    # fails, keep the result accurate for earlier items that are already valid.
    if runtime_matches_current_metadata "$runtime"; then
      printf 'OK\truntime\t%s\tnative\n' "$runtime" >> "$RESULT_FILE"
    elif [ -e "$CANCEL_FILE" ]; then
      printf 'FAIL\truntime\t%s\tcancelled\n' "$runtime" >> "$RESULT_FILE"
    else
      printf 'FAIL\truntime\t%s\trepair\n' "$runtime" >> "$RESULT_FILE"
    fi
  done < "$PLAN_FILE"
  rm -f -- "$output"
  return 1
}

pam_cache_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf 0
}

pam_check_update() {
  local now mtime tmp parsed latest _url _md5 status="error"
  pam_update_allowed || return 0
  now=$(date +%s 2>/dev/null || printf 0)
  mtime=$(pam_cache_mtime "$UPDATE_CACHE_FILE")
  case "$now:$mtime" in *[!0-9:]*|:) mtime=0 ;; esac
  if [ "$FORCE_UPDATE_CHECK" != "1" ] && [ "$mtime" -gt 0 ] && [ $((now - mtime)) -lt 86400 ]; then return 0; fi

  tmp="$CONFDIR/.portmaster-version.$$"
  rm -f -- "$tmp"
  rm -f -- "$CANCEL_FILE"
  "$PAM_APPMANAGER_CLI" fetch-stable-manifest \
    --source "$(pm_release_version_url)" --output "$tmp" >/dev/null 2>> "$PAM_APP_ROOT/log.txt" || true
  parsed="$tmp.stable"
  if pam_stable_metadata_parse "$tmp" "$parsed"; then
    IFS=$'\t' read -r latest _url _md5 < "$parsed"
  fi
  rm -f -- "$parsed"
  case "$latest" in ""|*[!A-Za-z0-9._-]*) latest="" ;; *) status="ok" ;; esac
  printf '%s\t%s\t%s\n' "$now" "$status" "$latest" > "$UPDATE_CACHE_FILE.tmp" &&
    mv -f "$UPDATE_CACHE_FILE.tmp" "$UPDATE_CACHE_FILE"
  rm -f -- "$tmp"
  [ "$status" = "ok" ]
}

runtime_file_size() {
  [ -f "$1" ] || { echo 0; return; }
  wc -c < "$1" | tr -d '[:space:]'
}

pm_cancel_requested() { [ -e "$CANCEL_FILE" ]; }

pam_config_refresh_deadline() {
  local seconds="${PAM_CONFIG_REFRESH_TIMEOUT_SECONDS:-40}"
  case "$seconds" in ''|*[!0-9]*) seconds=40 ;; esac
  # Lua waits 45 seconds.  Leave a margin for validation and atomic promotion.
  [ "$seconds" -ge 1 ] && [ "$seconds" -le 44 ] || seconds=40
  printf '%s\n' "$seconds"
}

pam_config_refresh_session_matches() {
  local token="$1" deadline="$2" current_token current_deadline now
  IFS=$'\t' read -r current_token current_deadline < "$CONFIG_REFRESH_SESSION" 2>/dev/null || return 1
  [ "$current_token" = "$token" ] && [ "$current_deadline" = "$deadline" ] || return 1
  now=$(date +%s 2>/dev/null || printf 0)
  case "$now:$deadline" in *[!0-9:]*|:) return 1 ;; esac
  [ "$now" -le "$deadline" ]
}

pam_config_version_is_newer() {
  local candidate="$1" baseline="$2" c1 c2 c3 extra b1 b2 b3
  IFS=. read -r c1 c2 c3 extra <<EOF
$candidate
EOF
  [ -z "$extra" ] || return 1
  IFS=. read -r b1 b2 b3 extra <<EOF
$baseline
EOF
  [ -z "$extra" ] || return 1
  case "$c1:$c2:$c3:$b1:$b2:$b3" in *[!0-9:]*) return 1 ;; esac
  awk -v c1="$c1" -v c2="$c2" -v c3="$c3" -v b1="$b1" -v b2="$b2" -v b3="$b3" \
    'BEGIN { exit !((c1 > b1) || (c1 == b1 && c2 > b2) || (c1 == b1 && c2 == b2 && c3 > b3)) }'
}

pam_valid_config_version() {
  local root="$1" config_dir="$2" launcher="$3" output="$4" platform version extra
  set -- config select-detail --config "$root" --launcher "$launcher" --format tsv
  [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
  "$PAM_PORTKIT" "$@" > "$output" 2>/dev/null || return 1
  platform=$(awk -F '\t' '$1 == "platform_id" && NF == 2 {print $2}' "$output")
  version=$(awk -F '\t' '$1 == "config_version" && NF == 2 {print $2}' "$output")
  [ -n "$platform" ] && [ -n "$version" ] || return 1
  "$PAM_PORTKIT" config validate --config "$root" --config-dir "$config_dir" \
    --platform "$platform" >/dev/null 2>&1 || return 1
  printf '%s\n' "$version"
}

pam_refresh_device_config() {
  local stage="$CONFDIR/device-config-stage.$$" staged detail_file detail_target detail_url
  local status=unchanged rc=0 started timeout deadline token native_launcher
  local packaged_version cached_version baseline_version
  local key value schema="" config_version="" platform_id="" detail_ref="" detail_sha256=""
  started=$(date +%s 2>/dev/null || printf 0)
  timeout=$(pam_config_refresh_deadline)
  case "$started" in ''|*[!0-9]*) started=0 ;; esac
  deadline=$((started + timeout))
  token="$$-$started-$RANDOM"
  printf '%s\t%s\n' "$token" "$deadline" > "$CONFIG_REFRESH_SESSION.tmp.$$" &&
    mv -f -- "$CONFIG_REFRESH_SESSION.tmp.$$" "$CONFIG_REFRESH_SESSION" || return 1
  printf '1\trunning\n' > "$CONFIG_REFRESH_RESULT.tmp.$$" &&
    mv -f -- "$CONFIG_REFRESH_RESULT.tmp.$$" "$CONFIG_REFRESH_RESULT" || return 1
  PAM_CONFIG_REFRESH_DEADLINE="$deadline"
  export PAM_CONFIG_REFRESH_DEADLINE
  rm -rf -- "$stage"
  if [ -L "$DEVICE_CONFIG_DIR" ] || [ -L "$DEVICE_CONFIG_DIR/platforms" ] ||
     ! mkdir -p "$stage/platforms"; then
    rc=74; status=error
  else
    staged="$stage/config.json"
    native_launcher="${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_LAUNCHER_SOURCE}"
    case "$native_launcher" in /*) ;; *) native_launcher="$PAM_DIR/$(basename "$native_launcher")" ;; esac
    if ! "$PAM_PORTKIT" github fetch --capability raw --source "$PAM_DEVICE_CONFIG_URL" \
         --output "$staged" --max-bytes 4194304 --validator config-root >/dev/null 2>&1; then
      rc=$?; [ "$rc" = "0" ] && rc=69; status=error
    else
      set -- config select-detail --config "$staged" --launcher "$native_launcher" --format tsv
      [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
      if ! "$PAM_PORTKIT" "$@" > "$stage/selection.tsv" 2>/dev/null; then
        rc=65; status=error
      else
        while IFS=$'\t' read -r key value extra; do
          [ -z "$extra" ] || { rc=65; break; }
          case "$value" in *$'\t'*|*$'\r'*|*$'\n'*) rc=65; break ;; esac
          case "$key" in
            schema) [ -z "$schema" ] || { rc=65; break; }; schema="$value" ;;
            config_version) [ -z "$config_version" ] || { rc=65; break; }; config_version="$value" ;;
            platform_id) [ -z "$platform_id" ] || { rc=65; break; }; platform_id="$value" ;;
            detail_ref) [ -z "$detail_ref" ] || { rc=65; break; }; detail_ref="$value" ;;
            detail_sha256) [ -z "$detail_sha256" ] || { rc=65; break; }; detail_sha256="$value" ;;
            *) rc=65; break ;;
          esac
        done < "$stage/selection.tsv"
        case "$schema:$platform_id:$detail_ref:$detail_sha256" in
          1:[A-Za-z0-9_-]*:./platforms/[A-Za-z0-9_.-]*.json:[0-9a-f][0-9a-f]*) ;;
          *) rc=65 ;;
        esac
        case "$detail_sha256" in *[!0-9a-f]*) rc=65 ;; esac
        [ "${#detail_sha256}" = 64 ] || rc=65
        [ "$detail_ref" = "./platforms/$platform_id.json" ] || rc=65
        if [ "$rc" = "0" ]; then
          detail_file="$stage/${detail_ref#./}"
          detail_url="${PAM_DEVICE_CONFIG_URL%/config.json}/${detail_ref#./}"
          "$PAM_PORTKIT" github fetch --capability raw --source "$detail_url" \
            --output "$detail_file" --max-bytes 4194304 --expected-sha256 "$detail_sha256" \
            >/dev/null 2>&1 || rc=$?
        fi
        if [ "$rc" = "0" ]; then
          "$PAM_PORTKIT" config validate --config "$staged" --config-dir "$stage" \
            --platform "$platform_id" >/dev/null 2>&1 || rc=65
        fi
        if [ "$rc" = "0" ] && pam_config_refresh_session_matches "$token" "$deadline"; then
          detail_target="$DEVICE_CONFIG_DIR/${detail_ref#./}"
          packaged_version=$(pam_valid_config_version "$PAM_CONFIG_DIR/config.json" "$PAM_CONFIG_DIR" \
            "$native_launcher" "$stage/packaged-selection.tsv" 2>/dev/null || true)
          [ -n "$packaged_version" ] || { rc=65; status=error; }
          baseline_version="$packaged_version"
          if [ "$rc" = "0" ] && [ -s "$DEVICE_CONFIG_FILE" ]; then
            cached_version=$(pam_valid_config_version "$DEVICE_CONFIG_FILE" "$DEVICE_CONFIG_DIR" \
              "$native_launcher" "$stage/cached-selection.tsv" 2>/dev/null || true)
            if [ -n "$cached_version" ] && pam_config_version_is_newer "$cached_version" "$baseline_version"; then
              baseline_version="$cached_version"
            fi
          fi
          if [ "$rc" = "0" ] && ! pam_config_version_is_newer "$config_version" "$baseline_version"; then
            status=unchanged
          elif [ "$rc" = "0" ] && [ -s "$DEVICE_CONFIG_FILE" ] && [ -s "$detail_target" ] &&
             cmp -s "$staged" "$DEVICE_CONFIG_FILE" && cmp -s "$detail_file" "$detail_target"; then
            status=unchanged
          elif [ "$rc" = "0" ] && mkdir -p "$DEVICE_CONFIG_DIR/platforms" &&
               mv -f -- "$detail_file" "$detail_target" &&
               mv -f -- "$staged" "$DEVICE_CONFIG_FILE"; then
            status=updated
          elif [ "$rc" = "0" ]; then
            rc=74; status=error
          fi
        elif [ "$rc" = "0" ]; then
          rc=70; status=error
        else
          status=error
        fi
      fi
    fi
  fi
  rm -rf -- "$stage"
  printf '1\t%s\n' "$status" > "$CONFIG_REFRESH_RESULT.tmp.$$" &&
    mv -f -- "$CONFIG_REFRESH_RESULT.tmp.$$" "$CONFIG_REFRESH_RESULT"
  return "$rc"
}

pam_refresh_native_inventory() {
  local tmp="$INVENTORY_FILE.tmp.$$" native_launcher
  [ "$PAM_NATIVE_PROFILE_ACTIVE" = 1 ] || return 1
  pam_capability_enabled "$PAM_CAPABILITY_MANAGE_PORTS" || return 1
  [ -x "$PAM_APPMANAGER_CLI" ] || return 1
  native_launcher="${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_LAUNCHER_SOURCE}"
  case "$native_launcher" in /*) ;; *) native_launcher="$PAM_DIR/$(basename "$native_launcher")" ;; esac
  set -- --config-dir "$PAM_CONFIG_DIR" device-inventory \
    --launcher "$native_launcher" \
    --app-state "$CONFDIR" \
    --trash "$TRASH_DIR" \
    --format json \
    --ignore-dir PortMaster \
    --ignore-dir autoinstall \
    --ignore-dir images \
    --ignore-dir "$PORT_NAME" \
    --ignore-script PortMaster.sh \
    --ignore-script "$(basename "$PAM_LAUNCHER_SOURCE")" \
    --ignore-script .port.sh \
    --self-port "$PORT_NAME" \
    --directory "$directory" \
    --controlfolder "$controlfolder" \
    --home "$HOME"
  [ "$param_device" != miniloong ] || set -- "$@" --scan-script-images
  [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
  [ -s "$DEVICE_CONFIG_FILE" ] && set -- "$@" --remote-config "$DEVICE_CONFIG_FILE" --remote-config-dir "$DEVICE_CONFIG_DIR"
  [ -z "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || set -- "$@" --target-override "$PAM_NATIVE_TARGET_DEVICE"
  if "$PAM_APPMANAGER_CLI" "$@" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f -- "$tmp" "$INVENTORY_FILE"
  else
    rm -f -- "$tmp"
    return 1
  fi
}

pm_sha256_file() {
  [ -x "$PAM_PORTKIT" ] &&
    "$PAM_PORTKIT" file digest --algorithm sha256 --input "$1" --format raw
}

pam_fetch_release_archive() {
  local source="$1" output="$2" expected_md5="$3" rc=0
  runtime_progress_write probing 14 0 "Checking connection"
  "$PAM_PORTKIT" github fetch --capability release --source "$source" --output "$output" \
    --expected-md5 "$expected_md5" --progress "$PROGRESS_FILE" \
    --progress-runtime PortMaster --progress-index 1 --progress-count 1 \
    --cancel-file "$CANCEL_FILE" >/dev/null 2>> "$PAM_APP_ROOT/log.txt" || rc=$?
  if pm_cancel_requested; then
    runtime_progress_write cancelled 0 0 "Cancelled"
    return 70
  fi
  if [ "$rc" != 0 ]; then
    runtime_progress_write failed 0 0 "Download failed"
    return "$rc"
  fi
  runtime_progress_write downloading 78 0 "Download complete"
}

pam_write_native_install_plan() {
  local plan="$1" tmp="$plan.tmp.$$" native_launcher
  [ "$PAM_NATIVE_PROFILE_ACTIVE" = 1 ] || return 1
  [ -x "$PAM_APPMANAGER_CLI" ] || return 1
  native_launcher="${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_LAUNCHER_SOURCE}"
  case "$native_launcher" in /*) ;; *) native_launcher="$PAM_DIR/$(basename "$native_launcher")" ;; esac
  set -- --config-dir "$PAM_CONFIG_DIR" generate-device-install-plan \
    --launcher "$native_launcher" \
    --app-state "$CONFDIR" \
    --trash "$TRASH_DIR" \
    --format tsv
  [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
  [ -s "$DEVICE_CONFIG_FILE" ] && set -- "$@" --remote-config "$DEVICE_CONFIG_FILE" --remote-config-dir "$DEVICE_CONFIG_DIR"
  [ -z "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || set -- "$@" --target-override "$PAM_NATIVE_TARGET_DEVICE"
  "$PAM_APPMANAGER_CLI" "$@" > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  [ -s "$tmp" ] && mv -f -- "$tmp" "$plan" || { rm -f -- "$tmp"; return 1; }
}

pam_write_install_plan() {
  pam_write_native_install_plan "$1"
}

pm_release_version_url() {
  pam_release_manifest_url
}

pm_valid_stable_archive_url() {
  local manifest base archive_name
  manifest=$(pam_release_manifest_url)
  archive_name=$(pam_release_archive_name) || return 1
  case "$manifest" in
    https://github.com/*/*/releases/latest/download/version.json)
      base=${manifest%/latest/download/version.json}/download
      case "$1" in "$base"/*/"$archive_name") return 0 ;; esac
      return 1
      ;;
  esac
  return 1
}

pm_valid_md5() {
  case "$1" in ""|*[!0-9A-Fa-f]*) return 1 ;; esac
  [ "${#1}" = 32 ]
}

pam_install_portmaster_native() {
  local archive="$1" native_launcher
  [ -x "$PAM_APPMANAGER_CLI" ] || return 69
  native_launcher="${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_LAUNCHER_SOURCE}"
  case "$native_launcher" in /*) ;; *) native_launcher="$PAM_DIR/$(basename "$native_launcher")" ;; esac
  set -- --config-dir "$PAM_CONFIG_DIR" install-portmaster \
    --archive "$archive" \
    --launcher "$native_launcher" \
    --app-state "$CONFDIR" \
    --trash "$TRASH_DIR" \
    --cancel-file "$CANCEL_FILE"
  [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
  [ -s "$DEVICE_CONFIG_FILE" ] && set -- "$@" --remote-config "$DEVICE_CONFIG_FILE" --remote-config-dir "$DEVICE_CONFIG_DIR"
  [ -z "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || set -- "$@" --target-override "$PAM_NATIVE_TARGET_DEVICE"
  "$PAM_APPMANAGER_CLI" "$@"
}

install_portmaster_release_inner() {
  local cache="$CONFDIR/portmaster-download" version metadata archive archive_dir rc
  local version_url stable_url stable_version expected_hash actual_hash archive_valid=0 reason archive_name
  version="$cache/version.json"
  metadata="$cache/version.tsv"
  rm -f -- "$CANCEL_FILE"; mkdir -p "$cache" || return 1
  rm -f -- "$version" "$metadata" "$cache/appmanager-installer.sh" "$cache/appmanager-installer.sh.new"
  RUNTIME_PROGRESS_RUNTIME="PortMaster"
  runtime_progress_write preparing 1 0 "Preparing PortMaster"
  ensure_portmaster_python_runtime || {
    printf 'FAIL\tportmaster\tpython-runtime\n' >> "$RESULT_FILE"
    return 1
  }
  pam_release_route_allowed || { printf 'FAIL\tportmaster\tcapability-disabled\n' >> "$RESULT_FILE"; return 1; }
  version_url=$(pm_release_version_url)
  "$PAM_APPMANAGER_CLI" fetch-stable-manifest \
    --source "$version_url" --output "$version" >/dev/null 2>> "$PAM_APP_ROOT/log.txt" || {
      rc=$?; printf 'FAIL\tportmaster\t%s\n' "$([ -e "$CANCEL_FILE" ] && echo cancelled || echo network)" >> "$RESULT_FILE"; return 1;
    }
  pam_stable_metadata_parse "$version" "$metadata" || { printf 'FAIL\tportmaster\tversion\n' >> "$RESULT_FILE"; return 1; }
  IFS=$'\t' read -r stable_version stable_url expected_hash < "$metadata"
  case "$stable_version" in ""|*[!A-Za-z0-9._-]*) printf 'FAIL\tportmaster\tversion\n' >> "$RESULT_FILE"; return 1 ;; esac
  pm_valid_stable_archive_url "$stable_url" || { printf 'FAIL\tportmaster\tversion-url\n' >> "$RESULT_FILE"; return 1; }
  archive_name=$(pam_release_archive_name) || { printf 'FAIL\tportmaster\tversion-url\n' >> "$RESULT_FILE"; return 1; }
  case "$stable_url" in */releases/download/"$stable_version"/"$archive_name") ;; *) printf 'FAIL\tportmaster\tversion-url\n' >> "$RESULT_FILE"; return 1 ;; esac
  archive_dir="$cache/$stable_version"; archive="$archive_dir/$archive_name"
  mkdir -p "$archive_dir" || return 1

  pm_valid_md5 "$expected_hash" || { printf 'FAIL\tportmaster\tversion-md5\n' >> "$RESULT_FILE"; return 1; }
  expected_hash=$(printf '%s' "$expected_hash" | tr '[:upper:]' '[:lower:]')
  if [ -s "$archive" ]; then
    actual_hash=$(runtime_md5_file "$archive" 2>/dev/null || true)
    [ "$(printf '%s' "$actual_hash" | tr '[:upper:]' '[:lower:]')" = "$expected_hash" ] && archive_valid=1
  fi
  if [ "$archive_valid" = "1" ]; then
    runtime_progress_write downloading 78 0 "Using local cache"
  else
    pam_fetch_release_archive "$stable_url" "$archive" "$expected_hash" || {
      rc=$?
      case "$rc" in 70) reason=cancelled ;; 65) reason=checksum ;; *) reason=network ;; esac
      printf 'FAIL\tportmaster\t%s\n' "$reason" >> "$RESULT_FILE"; return 1
    }
  fi
  runtime_progress_write verifying 82 0 "Verifying release assets"
  actual_hash=$(runtime_md5_file "$archive" 2>/dev/null || true)
  if [ "$(printf '%s' "$actual_hash" | tr '[:upper:]' '[:lower:]')" != "$expected_hash" ]; then
    # A completed but invalid file is never retained. Retry once without a
    # range so a bad cache cannot poison later launches.
    rm -f -- "$archive"
    pam_fetch_release_archive "$stable_url" "$archive" "$expected_hash" || {
      rc=$?
      case "$rc" in 70) reason=cancelled ;; 65) reason=checksum ;; *) reason=network ;; esac
      printf 'FAIL\tportmaster\t%s\n' "$reason" >> "$RESULT_FILE"; return 1
    }
    actual_hash=$(runtime_md5_file "$archive" 2>/dev/null || true)
    [ "$(printf '%s' "$actual_hash" | tr '[:upper:]' '[:lower:]')" = "$expected_hash" ] || {
      rm -f -- "$archive"; printf 'FAIL\tportmaster\tchecksum\n' >> "$RESULT_FILE"; return 1;
    }
  fi
  if [ ! -s "$archive" ]; then
    echo "$LOG_PREFIX cached PortMaster archive did not match the current stable release; restarting"
    rm -f -- "$archive"
    printf 'FAIL\tportmaster\tchecksum\n' >> "$RESULT_FILE"; return 1
  fi
  pam_zip_readable "$archive" || {
    printf 'FAIL\tportmaster\tarchive\n' >> "$RESULT_FILE"; return 1;
  }
  pm_cancel_requested && { printf 'FAIL\tportmaster\tcancelled\n' >> "$RESULT_FILE"; return 1; }
  runtime_progress_write installing 88 0 "Installing PortMaster"
  pam_install_portmaster_native "$archive" || {
    rc=$?; printf 'FAIL\tportmaster\tinstaller-%s\n' "$rc" >> "$RESULT_FILE"; return 1;
  }
  [ -s "$CONFDIR/pending-install.tsv" ] && [ -s "$CONFDIR/pending-manifest.tsv" ] &&
    [ -f "$CONFDIR/pending-frontend-manifest.tsv" ] || {
    printf 'FAIL\tportmaster\tpending-validation\n' >> "$RESULT_FILE"; return 1;
  }
  runtime_progress_write complete 100 0 "Installation complete; reopen required"
  printf 'OK\tportmaster\tpending-validation\n' >> "$RESULT_FILE"
}

install_portmaster_release() {
  local rc token
  if ! pam_lock_acquire "$PORTMASTER_ACTIVE_LOCK" --apply-plan; then
    printf 'FAIL\tportmaster\talready-running\n' >> "$RESULT_FILE"
    return 1
  fi
  token="$PAM_LOCK_TOKEN"
  {
    printf 'version\t1\n'
    printf 'token\t%s\n' "$token"
    printf 'pid\t%s\n' "$$"
    printf 'started\t%s\n' "$(date +%s 2>/dev/null || echo 0)"
  } > "$PORTMASTER_ACTIVE_FILE.tmp.$$" &&
    mv -f -- "$PORTMASTER_ACTIVE_FILE.tmp.$$" "$PORTMASTER_ACTIVE_FILE" || {
      pam_lock_release "$PORTMASTER_ACTIVE_LOCK" "$token" || true
      return 1
    }
  install_portmaster_release_inner; rc=$?
  if [ "$(awk -F '\t' '$1 == "token" {print $2; exit}' "$PORTMASTER_ACTIVE_FILE" 2>/dev/null || true)" = "$token" ]; then
    rm -f -- "$PORTMASTER_ACTIVE_FILE"
  fi
  pam_lock_release "$PORTMASTER_ACTIVE_LOCK" "$token" || true
  return "$rc"
}

runtime_md5_file() {
  [ -x "$PAM_PORTKIT" ] &&
    "$PAM_PORTKIT" file digest --algorithm md5 --input "$1" --format raw
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
  if ! pam_repair_runtime_native "$runtime"; then
    PORTMASTER_BOOTSTRAP_PROGRESS=0
    PORTMASTER_BOOTSTRAP_BYTES=0
    return 1
  fi
  PORTMASTER_BOOTSTRAP_PROGRESS=0
  PORTMASTER_BOOTSTRAP_BYTES=0
  PORTMASTER_PROGRESS_FLOOR=35
  runtime_matches_current_metadata "$runtime"
}

pam_cleanup_appledouble() {
  local candidate root item count=0 duplicate
  set --
  for candidate in "$GAMEDIRS_DIR" "$SCRIPTS_DIR" "$IMAGES_DIR"; do
    [ -n "$candidate" ] && [ "$candidate" != "/" ] && [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
    case "$candidate" in /*) ;; *) continue ;; esac
    duplicate=0
    for root in "$@"; do
      case "$candidate/" in "$root/"*) duplicate=1; break ;; esac
    done
    [ "$duplicate" = "1" ] || set -- "$@" "$candidate"
  done
  [ "$#" -gt 0 ] || return 1

  RUNTIME_PROGRESS_COUNT=1
  RUNTIME_PROGRESS_INDEX=1
  RUNTIME_PROGRESS_TOTAL_BYTES=0
  RUNTIME_PROGRESS_RUNTIME="AppleDouble"
  runtime_progress_write scanning 0 0 "Scanning Port directories"
  for root in "$@"; do
    while IFS= read -r -d '' item; do
      [ -f "$item" ] && [ ! -L "$item" ] || continue
      case "$(basename "$item")" in ._*) ;; *) continue ;; esac
      if $ESUDO rm -f -- "$item"; then
        count=$((count + 1))
        if [ $((count % 10)) -eq 0 ]; then
          runtime_progress_write cleaning "$count" 0 "Removed $count files"
        fi
      else
        printf 'FAIL\tappledouble\t%s\n' "$count" >> "$RESULT_FILE"
        return 1
      fi
    done < <(find "$root" -xdev -type f -name '._*' -print0 2>/dev/null)
  done
  runtime_progress_write indexing "$count" 0 "Updating size information"
  scan_sizes || rm -f -- "$SIZE_FILE"
  runtime_progress_write complete "$count" 0 "Removed $count files"
  printf 'OK\tappledouble\t%s\n' "$count" >> "$RESULT_FILE"
}

apply_plan() {
  local stamp kind arg dest base bucket batch item trash_failed=0 empty_failed=0
  local device_risk_ack=0 device_support_ack=0 runtime_metadata_ready=1 native_runtime_handled=0
  stamp=$(date +%Y%m%d-%H%M%S)
  : > "$RESULT_FILE"
  rm -f -- "$PROGRESS_FILE" "$PROGRESS_FILE.tmp.$$"
  if [ ! -f "$PLAN_FILE" ]; then
    printf 'FAIL\toperation\n' >> "$RESULT_FILE"
    return
  fi
  SIZE_MUTATIONS="$CONFDIR/size-mutations.$$"
  : > "$SIZE_MUTATIONS"
  if grep -q $'^INSTALL_RUNTIME\t' "$PLAN_FILE" 2>/dev/null; then
    if ! pam_runtime_repair_allowed; then
      runtime_metadata_ready=0
      echo "$LOG_PREFIX Runtime repair is disabled by the device profile"
    else
      RUNTIME_PROGRESS_COUNT=$(grep -c $'^INSTALL_RUNTIME\t' "$PLAN_FILE" 2>/dev/null || echo 0)
      RUNTIME_PROGRESS_RUNTIME="Runtime"
      runtime_progress_write probing 0 0 "Updating official Runtime information"
      if ! runtime_metadata_refresh 1; then
        runtime_metadata_ready=0
        echo "$LOG_PREFIX unable to refresh official Runtime information"
      fi
    fi
  fi
  runtime_progress_prepare_plan

  while IFS=$'\t' read -r kind arg; do
    case "$kind" in
      \#*|"") continue ;;

      TRASH|DELETE_MANAGED)
        if ! pam_capability_enabled "$PAM_CAPABILITY_MANAGE_PORTS" ||
           ! pam_capability_enabled "$PAM_CAPABILITY_TRASH"; then
          printf 'FAIL\toperation\tcapability-disabled\n' >> "$RESULT_FILE"
          continue
        fi
        # UI 只能处理三个受管根目录的直接子项。即使 plan.txt 损坏，也不能让提权的
        # shell 移动或删除任意路径；本 APP、PortMaster 和临时 .port.sh 再额外挡一次。
        base=$(basename "$arg")
        if ! { [ "$(dirname "$arg")" = "$SCRIPTS_DIR" ] &&
                 { [[ "$base" = *.sh ]] || pam_is_image_name "$base"; } ||
               { [ -n "$IMAGES_DIR" ] && [ "$(dirname "$arg")" = "$IMAGES_DIR" ] &&
                 pam_is_image_name "$base"; } ||
               [ "$(dirname "$arg")" = "$GAMEDIRS_DIR" ]; } ||
           [ "$arg" = "$GAMEDIR" ] ||
           [ "$arg" = "$PAM_DIR/$(basename "$0")" ] ||
           [ "$base" = "APP Manager.sh" ] ||
           { [ "$(dirname "$arg")" = "$PAM_DIR" ] && [ "$base" = "APP Manager.png" ]; } ||
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
            size_cache_record_delete "$arg"
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
        elif [ "$(dirname "$arg")" = "$SCRIPTS_DIR" ] && pam_is_image_name "$base"; then bucket="script-images"
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
          size_cache_record_move "$arg" "$dest/$base"
          echo "$LOG_PREFIX moved to trash: $base"
        else
          printf 'FAIL\ttrash\t%s\n' "$base" >> "$RESULT_FILE"
          trash_failed=1
          $ESUDO rmdir -- "$dest" "$TRASH_DIR/$stamp" 2>/dev/null || true
        fi
        ;;

      EMPTY_TRASH)
        if ! pam_capability_enabled "$PAM_CAPABILITY_TRASH"; then
          printf 'FAIL\tempty_trash\tcapability-disabled\n' >> "$RESULT_FILE"
          continue
        fi
        empty_failed=0
        # 普通 * 不包含隐藏项；三组 glob 才能完整覆盖，并且始终限定在 APP 回收站内。
        for item in "$TRASH_DIR"/* "$TRASH_DIR"/.[!.]* "$TRASH_DIR"/..?*; do
          [ -e "$item" ] || [ -L "$item" ] || continue
          if $ESUDO rm -rf -- "$item"; then
            size_cache_record_delete "$item"
          else
            empty_failed=1
          fi
        done
        if [ "$empty_failed" = "1" ]; then
          printf 'FAIL\tempty_trash\n' >> "$RESULT_FILE"
        else
          echo "$LOG_PREFIX trash emptied"
        fi
        ;;

      RESTORE_TRASH)
        if ! pam_capability_enabled "$PAM_CAPABILITY_TRASH"; then
          printf 'FAIL\trestore\tcapability-disabled\n' >> "$RESULT_FILE"
          continue
        fi
        # 新格式按来源分类，可精确恢复。旧版扁平批次则用安全可推导的
        # 类型兼容：.sh 回 SH 目录，目录回 Data，其余文件回图片目录。
        for batch in "$TRASH_DIR"/* "$TRASH_DIR"/.[!.]* "$TRASH_DIR"/..?*; do
          [ -d "$batch" ] || continue
          if [ -L "$batch" ]; then
            printf 'FAIL\trestore\t%s\n' "$(basename "$batch")" >> "$RESULT_FILE"
            continue
          fi
          restore_bucket "$batch/scripts" "$SCRIPTS_DIR" scripts
          restore_bucket "$batch/script-images" "$SCRIPTS_DIR" script-images
          restore_bucket "$batch/images" "$IMAGES_DIR" images
          restore_bucket "$batch/data" "$GAMEDIRS_DIR" data
          for item in "$batch"/* "$batch"/.[!.]* "$batch"/..?*; do
            [ -e "$item" ] || [ -L "$item" ] || continue
            base=$(basename "$item")
            case "$base" in scripts|script-images|images|data) [ -d "$item" ] && continue ;; esac
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
        if pam_capability_enabled "$PAM_CAPABILITY_TRASH"; then restore_selected_item "$arg"
        else printf 'FAIL\trestore\tcapability-disabled\n' >> "$RESULT_FILE"; fi
        ;;

      DELETE_ITEM)
        if pam_capability_enabled "$PAM_CAPABILITY_TRASH"; then delete_selected_item "$arg"
        else printf 'FAIL\tdelete\tcapability-disabled\n' >> "$RESULT_FILE"; fi
        ;;

      CLEAN_APPLEDOUBLE)
        if ! pam_capability_enabled "$PAM_CAPABILITY_CLEANUP_APPLEDOUBLE" ||
           [ "$arg" != "-" ] || ! pam_cleanup_appledouble; then
          printf 'FAIL\tappledouble\n' >> "$RESULT_FILE"
        fi
        ;;

      INSTALL_RUNTIME)
        if ! pam_runtime_repair_allowed; then
          printf 'FAIL\truntime\t%s\tcapability-disabled\n' "$arg" >> "$RESULT_FILE"
          continue
        fi
        if [ "$native_runtime_handled" = "0" ]; then
          native_runtime_handled=1
          if [ "$runtime_metadata_ready" = "1" ]; then
            pam_repair_plan_runtimes_native || true
          else
            while IFS=$'\t' read -r kind arg; do
              [ "$kind" = "INSTALL_RUNTIME" ] || continue
              printf 'FAIL\truntime\t%s\tmetadata\n' "$arg" >> "$RESULT_FILE"
            done < "$PLAN_FILE"
          fi
        fi
        continue
        ;;

      INSTALL_PORTMASTER)
        if [ "$PAM_PORTMASTER_MANAGEMENT" = "system" ]; then
          printf 'FAIL\tportmaster\tsystem-managed\n' >> "$RESULT_FILE"
        elif ! pam_release_route_allowed; then
          printf 'FAIL\tportmaster\tcapability-disabled\n' >> "$RESULT_FILE"
        elif [ "$arg" != "stable" ]; then
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

  if [ "$RUNTIME_PROGRESS_COUNT" -gt 0 ] && [ "$PORTMASTER_PROGRESS" != "1" ] &&
     [ "$native_runtime_handled" = "0" ]; then
    runtime_progress_write complete "$RUNTIME_PROGRESS_DONE_BYTES" 0 "Runtime repair complete"
  fi

  # The UI treats plan.txt removal as the completion signal. Publish the
  # small path-level delta first; never recursively rescan every game after a
  # trash/delete/restore operation on a slow SD card.
  size_cache_apply_mutations || echo "$LOG_PREFIX unable to update size cache"
  rm -f -- "$SIZE_MUTATIONS"

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
  [ "$PAM_FRONTEND_NAMES" != "-" ] || return 1
  case ",$PAM_FRONTEND_NAMES," in *",$1,"*) return 0 ;; esac
  return 1
}

pending_frontend_manifest_valid() {
  local file="$CONFDIR/pending-install.tsv" manifest="$CONFDIR/pending-frontend-manifest.tsv"
  local expected_hash expected_count actual hash name count=0
  [ -f "$manifest" ] || return 1
  expected_hash=$(state_value "$file" frontend_manifest_sha256) || return 1
  expected_count=$(state_value "$file" frontend_manifest_count) || return 1
  case "$expected_hash" in *[!0-9A-Fa-f]*|'') return 1 ;; esac
  [ "${#expected_hash}" = 64 ] || return 1
  case "$expected_count" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$PAM_FRONTEND_NAMES" = "-" ]; then
    [ "$expected_count" = "0" ] || return 1
  else
    [ "$expected_count" -gt 0 ] || return 1
  fi
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
  local expected_frontend_rollback
  local version protocol_version mode launcher_hash actual expected_frontend_dir expected_frontend_names
  protocol_version=$(state_value "$file" version) || return 1
  mode=$(state_value "$file" mode) || return 1
  expected_target=$(state_value "$file" target) || return 1
  expected_scripts=$(state_value "$file" scripts) || return 1
  expected_device=$(state_value "$file" device) || return 1
  expected_rollback=$(state_value "$file" rollback) || return 1
  launcher_hash=$(state_value "$file" launcher_sha256) || return 1
  [ "$protocol_version" = "1" ] || return 1
  case "$mode" in install|update) ;; *) return 1 ;; esac
  [ -n "$expected_target" ] && [ "$expected_target" = "$PAM_PORTMASTER_DIR" ] || return 1
  [ -n "$expected_scripts" ] && [ "$expected_scripts" = "$SCRIPTS_DIR" ] || return 1
  [ "$expected_rollback" = "$PAM_PORTMASTER_DIR/.appmanager-rollback" ] || return 1
  expected_frontend_dir=$(state_value "$file" frontend_dir) || return 1
  expected_frontend_names=$(state_value "$file" frontend_names) || return 1
  [ "$expected_frontend_dir" = "$PAM_FRONTEND_DIR" ] || return 1
  [ "$expected_frontend_names" = "$PAM_FRONTEND_NAMES" ] || return 1
  expected_frontend_rollback=$(state_value "$file" frontend_rollback) || return 1
  [ "$expected_frontend_rollback" = "$PAM_FRONTEND_DIR/.appmanager-rollback" ] || return 1
  case "$launcher_hash" in *[!0-9A-Fa-f]*|'') return 1 ;; esac
  [ "${#launcher_hash}" = 64 ] || return 1
  [ "$expected_device" = "$param_device" ] || return 1
  [ "$(pam_core_health)" = "healthy" ] || return 1
  version=$(pam_core_version); [ -n "$version" ] || return 1
  [ -f "$PAM_PORTMASTER_DIR/pugwash" ] || [ -f "$PAM_PORTMASTER_DIR/harbourmaster" ] || return 1
  actual=$(pm_sha256_file "$PAM_FRONTEND_LAUNCHER" 2>/dev/null || true)
  [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$launcher_hash" | tr '[:upper:]' '[:lower:]')" ] || return 1
  pending_manifest_valid || return 1
  pending_frontend_manifest_valid
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
  local frontend_rollback="$1" item base
  for item in "$frontend_rollback"/* "$frontend_rollback"/.[!.]* "$frontend_rollback"/..?*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    base=$(basename "$item")
    [ "$base" != "frontend-existing.tsv" ] || continue
    return 0
  done
  return 1
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
  local name failed=0 old_ifs
  [ "$PAM_FRONTEND_NAMES" != "-" ] || return 0
  old_ifs=$IFS; IFS=,; set -- $PAM_FRONTEND_NAMES; IFS=$old_ifs
  for name in "$@"; do
    [ -n "$name" ] || continue
    rm -f -- "$PAM_FRONTEND_DIR/$name" || failed=1
  done
  [ "$failed" = "0" ]
}

restore_rollback() {
  local rollback="$1" frontend_rollback="$2" sweep="$3"
  local expected_count="$4" expected_hash="$5" frontend_count="$6" frontend_hash="$7"
  local item top name backup live failed=0 restored=0 restore_count=0 old_ifs
  if [ "$expected_count" != "-" ]; then
    rollback_toplist_valid "$rollback" "$expected_count" "$expected_hash" || return 1
  fi
  rollback_frontend_list_valid "$frontend_rollback" "$frontend_count" "$frontend_hash" || return 1
  if [ -e "$rollback/restoring" ]; then
    sweep=0
    restored=1
  fi
  if [ "$sweep" = "1" ]; then
    : > "$rollback/sweeping" || return 1
    remove_current_managed_core || failed=1
    remove_current_frontend || failed=1
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
  if [ "$PAM_FRONTEND_NAMES" != "-" ]; then
    old_ifs=$IFS; IFS=,; set -- $PAM_FRONTEND_NAMES; IFS=$old_ifs
    for name in "$@"; do
      [ -n "$name" ] || continue
      backup="$frontend_rollback/$name"
      live="$PAM_FRONTEND_DIR/$name"
      if [ -e "$backup" ] || [ -L "$backup" ]; then
        if [ -e "$live" ] || [ -L "$live" ]; then failed=1
        else mv -- "$backup" "$live" || failed=1; restored=1; fi
      elif rollback_frontend_was_present "$frontend_rollback" "$name"; then
        [ -e "$live" ] || [ -L "$live" ] || failed=1
      elif [ "$sweep" = "1" ] || [ -e "$rollback/restoring" ]; then
        [ ! -e "$live" ] && [ ! -L "$live" ] || failed=1
      fi
    done
  fi
  rollback_has_core "$rollback" && failed=1
  rollback_has_frontend "$frontend_rollback" && failed=1
  if [ "$expected_count" != "-" ]; then
    while IFS= read -r top; do
      [ -e "$PAM_PORTMASTER_DIR/$top" ] || [ -L "$PAM_PORTMASTER_DIR/$top" ] || failed=1
    done < "$rollback/expected-tops.tsv"
  fi
  [ "$failed" = "0" ] || return 1
  rm -rf -- "$rollback" || return 1
  [ "$frontend_rollback" = "$rollback" ] || rm -rf -- "$frontend_rollback" || return 1
  [ "$restored" = "1" ] && return 0
  return 2
}

rollback_pending_core() {
  local file="$CONFDIR/pending-install.tsv" rollback backup_count backup_hash protocol_version
  local frontend_count frontend_hash frontend_rollback recorded_frontend_dir recorded_frontend_names
  local sweep=1 rc recorded_target recorded_scripts
  recorded_target=$(state_value "$file" target 2>/dev/null || true)
  recorded_scripts=$(state_value "$file" scripts 2>/dev/null || true)
  [ "$recorded_target" = "$PAM_PORTMASTER_DIR" ] && [ "$recorded_scripts" = "$SCRIPTS_DIR" ] || return 1
  protocol_version=$(state_value "$file" version 2>/dev/null || true)
  [ "$protocol_version" = "1" ] || return 1
  rollback=$(state_value "$file" rollback 2>/dev/null || true)
  backup_count=$(state_value "$file" backup_top_count 2>/dev/null || true)
  backup_hash=$(state_value "$file" backup_top_sha256 2>/dev/null || true)
  recorded_frontend_dir=$(state_value "$file" frontend_dir 2>/dev/null || true)
  recorded_frontend_names=$(state_value "$file" frontend_names 2>/dev/null || true)
  [ "$recorded_frontend_dir" = "$PAM_FRONTEND_DIR" ] && [ "$recorded_frontend_names" = "$PAM_FRONTEND_NAMES" ] || return 1
  frontend_count=$(state_value "$file" frontend_backup_count 2>/dev/null || true)
  frontend_hash=$(state_value "$file" frontend_backup_sha256 2>/dev/null || true)
  frontend_rollback=$(state_value "$file" frontend_rollback 2>/dev/null || true)
  [ "$frontend_rollback" = "$PAM_FRONTEND_DIR/.appmanager-rollback" ] || return 1
  [ "$rollback" = "$PAM_PORTMASTER_DIR/.appmanager-rollback" ] || return 1
  # The existence of backup content is safer evidence than damaged mode
  # metadata. It prevents a truncated update record from becoming first-install cleanup.
  restore_rollback "$rollback" "$frontend_rollback" "$sweep" "$backup_count" "$backup_hash" \
    "$frontend_count" "$frontend_hash"; rc=$?
  [ "$rc" = "1" ] && return 1
  rm -f -- "$CONFDIR/pending-install.tsv" "$CONFDIR/pending-manifest.tsv" \
    "$CONFDIR/pending-frontend-manifest.tsv" \
    "$CONFDIR/install-transaction.tsv" || return 1
  [ "$rc" = "0" ] && return 0
  return 2
}

recover_interrupted_transaction() {
  local file="$CONFDIR/install-transaction.tsv" protocol_version phase mode target scripts rollback had_launcher
  local backup_count backup_hash frontend_count frontend_hash frontend_dir frontend_names frontend_rollback sweep rc
  protocol_version=$(state_value "$file" version) || return 1
  phase=$(state_value "$file" phase) || return 1
  mode=$(state_value "$file" mode) || return 1
  target=$(state_value "$file" target) || return 1
  scripts=$(state_value "$file" scripts) || return 1
  rollback=$(state_value "$file" rollback) || return 1
  had_launcher=$(state_value "$file" had_launcher) || return 1
  backup_count=$(state_value "$file" backup_top_count) || return 1
  backup_hash=$(state_value "$file" backup_top_sha256) || return 1
  [ "$protocol_version" = "1" ] || return 1
  [ "$target" = "$PAM_PORTMASTER_DIR" ] && [ "$scripts" = "$SCRIPTS_DIR" ] || return 1
  frontend_dir=$(state_value "$file" frontend_dir) || return 1
  frontend_names=$(state_value "$file" frontend_names) || return 1
  frontend_count=$(state_value "$file" frontend_backup_count) || return 1
  frontend_hash=$(state_value "$file" frontend_backup_sha256) || return 1
  [ "$frontend_dir" = "$PAM_FRONTEND_DIR" ] && [ "$frontend_names" = "$PAM_FRONTEND_NAMES" ] || return 1
  frontend_rollback=$(state_value "$file" frontend_rollback) || return 1
  [ "$frontend_rollback" = "$PAM_FRONTEND_DIR/.appmanager-rollback" ] || return 1
  [ "$rollback" = "$PAM_PORTMASTER_DIR/.appmanager-rollback" ] || return 1
  case "$mode:$had_launcher" in install:0|install:1|update:0|update:1) ;; *) return 1 ;; esac
  case "$phase" in
    prepared) sweep=0; backup_count="-"; backup_hash="-" ;;
    backed-up) sweep=1 ;;
    *) return 1 ;;
  esac
  restore_rollback "$rollback" "$frontend_rollback" "$sweep" "$backup_count" "$backup_hash" \
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
    local frontend_rollback
    frontend_rollback=$(state_value "$CONFDIR/pending-install.tsv" frontend_rollback 2>/dev/null || true)
    rm -f -- "$CONFDIR/pending-install.tsv" "$CONFDIR/pending-manifest.tsv" \
      "$CONFDIR/pending-frontend-manifest.tsv" \
      "$CONFDIR/install-transaction.tsv" || {
        validation_write interrupted "Validated core could not finalize its pending state"
        return 75
      }
    rm -rf -- "$PAM_PORTMASTER_DIR/.appmanager-rollback" "$CONFDIR/rollback"
    rm -rf -- "$frontend_rollback"
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
  local lock="$CONFDIR/validation.lock" rc token
  if ! pam_lock_acquire "$lock" --validate-pending; then
    validation_write checking "Another validation process is still running"
    return 75
  fi
  token="$PAM_LOCK_TOKEN"
  validate_pending_install_inner; rc=$?
  pam_lock_release "$lock" "$token" || true
  return "$rc"
}

# ── 主入口 ────────────────────────────────────────────────────────────
# 容量统计会递归读整个游戏目录，绝不能放在 LÖVE 渲染线程。
# UI 用 --scan-sizes 后台启动这一模式；这里原子替换缓存，UI 始终可以
# 先读上一份完整结果。du 统计占用的磁盘块，比逻辑文件长度更接近真实
# 可释放空间。
size_bytes() {
  local path="$1" kb
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if command -v nice >/dev/null 2>&1; then
    kb=$(nice -n 19 du -sk "$path" 2>/dev/null | awk 'NR == 1 {print $1}')
  else
    kb=$(du -sk "$path" 2>/dev/null | awk 'NR == 1 {print $1}')
  fi
  case "$kb" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$((kb * 1024))"
}

scan_sizes() {
  local path batch bucket item structured
  set --
  SIZE_TMP="${SIZE_FILE}.tmp.$$"
  : > "$SIZE_TMP" || return 1

  # 首页与残留页使用的 Data 目录。APP Manager 自身另行统计
  # trash 的直接项，不把 runtime 等自身文件算进可卸载内容。
  for path in "$GAMEDIRS_DIR"/*; do
    [ -d "$path" ] && [ ! -L "$path" ] || continue
    [ "$path" = "$GAMEDIR" ] && continue
    set -- "$@" "$path"
  done

  # SH 和图片都是直接文件，同样记录后才能精确合并一个 Item。
  for path in "$SCRIPTS_DIR"/*.sh; do
    [ -f "$path" ] || continue
    set -- "$@" "$path"
  done
  for path in "$SCRIPTS_DIR"/*.png "$SCRIPTS_DIR"/*.PNG \
              "$SCRIPTS_DIR"/*.jpg "$SCRIPTS_DIR"/*.JPG \
              "$SCRIPTS_DIR"/*.jpeg "$SCRIPTS_DIR"/*.JPEG \
              "$SCRIPTS_DIR"/*.webp "$SCRIPTS_DIR"/*.WEBP; do
    [ -f "$path" ] || continue
    set -- "$@" "$path"
  done
  if [ -n "$IMAGES_DIR" ]; then
    for path in "$IMAGES_DIR"/*; do
      [ -f "$path" ] || continue
      set -- "$@" "$path"
    done
  fi

  # 回收站 UI 展示的是 batch 下各类型的直接项，缓存也保持同样
  # 粒度，才能对单个条目和彻底删除选中正确求和。
  for batch in "$TRASH_DIR"/* "$TRASH_DIR"/.[!.]* "$TRASH_DIR"/..?*; do
    [ -e "$batch" ] || [ -L "$batch" ] || continue
    if [ ! -d "$batch" ] || [ -L "$batch" ]; then
      set -- "$@" "$batch"
      continue
    fi
    structured=0
    for bucket in scripts script-images data images; do
      [ -d "$batch/$bucket" ] || continue
      structured=1
      for item in "$batch/$bucket"/* "$batch/$bucket"/.[!.]* "$batch/$bucket"/..?*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        set -- "$@" "$item"
      done
    done
    for item in "$batch"/* "$batch"/.[!.]* "$batch"/..?*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      if [ "$structured" = "1" ]; then
        case "$(basename "$item")" in scripts|script-images|data|images) continue ;; esac
      fi
      set -- "$@" "$item"
    done
  done

  # One du process handles every top-level item. This is materially cheaper
  # than starting a new process per Port on low-end CPUs and slow SD cards.
  if [ "$#" -gt 0 ]; then
    if command -v nice >/dev/null 2>&1; then
      nice -n 19 du -sk "$@" 2>/dev/null
    else
      du -sk "$@" 2>/dev/null
    fi | awk '
      $1 ~ /^[0-9]+$/ {
        kb=$1; sub(/^[^[:space:]]+[[:space:]]+/, "")
        print (kb * 1024) "\t" $0
      }
    ' >> "$SIZE_TMP"
  fi

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
  if ! pam_release_route_allowed; then
    echo "$LOG_PREFIX PortMaster is managed by the system; no install plan was created" >&2
    exit 1
  fi
  install_plan="$CONFDIR/portmaster-install-plan.tsv"
  pam_write_install_plan "$install_plan" || exit 1
  cat "$install_plan"
  exit 0
fi

if [ "$CONFIG_REFRESH_ONLY" = "1" ]; then
  pam_refresh_device_config
  exit $?
fi

if [ "$INVENTORY_ONLY" = "1" ]; then
  if pam_refresh_native_inventory; then exit 0; fi
  rm -f -- "$INVENTORY_FILE"
  exit 1
fi

if [ "$CHECK_UPDATE_ONLY" = "1" ]; then
  pam_check_update
  rc=$?
  write_env
  exit "$rc"
fi

if [ "$RUNTIME_METADATA_ONLY" = "1" ]; then
  pam_runtime_repair_allowed && runtime_metadata_refresh 0
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

if [ "$APPLY_ONLY" != "1" ]; then
  PAM_CORE_HEALTH_CACHE=$(pam_core_health)
  if [ "$PAM_PORTMASTER_MANAGEMENT" = system ] || [ "$PAM_CORE_HEALTH_CACHE" = healthy ]; then
    pam_refresh_native_inventory || rm -f -- "$INVENTORY_FILE"
  else
    rm -f -- "$INVENTORY_FILE"
  fi
fi
write_env
if [ "$ENV_ONLY" = "1" ]; then
  exit 0
fi
if [ "$APPLY_ONLY" = "1" ]; then
  apply_plan
  unset PAM_CORE_HEALTH_CACHE
  PAM_CORE_HEALTH_CACHE=$(pam_core_health)
  if [ "$PAM_PORTMASTER_MANAGEMENT" = system ] || [ "$PAM_CORE_HEALTH_CACHE" = healthy ]; then
    pam_refresh_native_inventory || rm -f -- "$INVENTORY_FILE"
  else
    rm -f -- "$INVENTORY_FILE"
  fi
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
  local love_pid key_pid=0 exit_code=1 native_launcher
  local wayland_dir="${XDG_RUNTIME_DIR:-/run}" wayland_name="${WAYLAND_DISPLAY:-wayland-0}"
  if [ ! -x "$PAM_APP_ROOT/runtime/love.aarch64" ] || [ ! -f "$PAM_APP_ROOT/love_ui/main.lua" ]; then
    echo "$LOG_PREFIX private LÖVE runtime or UI is missing"
    return 1
  fi
  export LOVE_IDENTITY="port_app_manager"
  export LOVE_WINDOW_TITLE="Port App Manager"
  export LOVE_FONT_PATH SDL_GAMECONTROLLERCONFIG_FILE SSL_CERT_FILE CURL_CA_BUNDLE
  export LIBGL_ES=2 LIBGL_GL=21
  if [ "$param_device" = "trimui" ]; then
    # The recommended TrimUI base packages use the GLES backend explicitly.
    # Keep the private LÖVE runtime aligned with their known-good launchers.
    export LOVE_GRAPHICS_USE_OPENGLES=1 SDL_VIDEO_GL_DRIVER=libGLESv2.so
  fi
  if [ -S "$wayland_dir/$wayland_name" ]; then
    export XDG_RUNTIME_DIR="$wayland_dir" WAYLAND_DISPLAY="$wayland_name" SDL_VIDEODRIVER=wayland
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
  if [ "$PAM_NATIVE_PROFILE_ACTIVE" = 1 ]; then
    native_launcher="${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_LAUNCHER_SOURCE}"
    case "$native_launcher" in /*) ;; *) native_launcher="$PAM_DIR/$(basename "$native_launcher")" ;; esac
    set -- env exec --config-dir "$PAM_CONFIG_DIR" --scope love_ui --launcher "$native_launcher" \
      --var "app_root=$PAM_APP_ROOT" \
      --var "state_dir=$CONFDIR" \
      --var "scripts_dir=$SCRIPTS_DIR" \
      --var "resolved_love_library_path=$PAM_LOVE_LIBRARY_PATH"
    [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
    [ -s "$DEVICE_CONFIG_FILE" ] && set -- "$@" --remote-config "$DEVICE_CONFIG_FILE" --remote-config-dir "$DEVICE_CONFIG_DIR"
    [ -z "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || set -- "$@" --target-override "$PAM_NATIVE_TARGET_DEVICE"
    set -- "$@" -- "$PAM_APP_ROOT/runtime/love.aarch64" "$PAM_APP_ROOT/love_ui"
    "$PAM_PORTKIT" "$@" &
  else
    env LD_LIBRARY_PATH="$PAM_LOVE_LIBRARY_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      "$PAM_APP_ROOT/runtime/love.aarch64" "$PAM_APP_ROOT/love_ui" &
  fi
  love_pid=$!
  wait "$love_pid"; exit_code=$?
  if [ "$key_pid" != "0" ]; then kill "$key_pid" 2>/dev/null; wait "$key_pid" 2>/dev/null || true; fi
  return "$exit_code"
}

run_portable_ui || true
pm_finish
exit 0
