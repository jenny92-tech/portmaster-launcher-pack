#!/bin/bash
# PORTMASTER: jenny92-appmanager, APP Manager.sh
#
# APP Manager — PortMaster 端口管理器。
#
# The UI is self-contained: it starts from the launcher-adjacent jenny92-appmanager
# directory even when PortMaster is missing. Lua submits declarative plans;
# the native helper validates and performs filesystem mutations.
#
# UI writes plan.txt and invokes this script's --apply-plan mode. The helper
# re-validates every path, then the running LÖVE UI invalidates
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
# A state helper or temporary .port.sh still represents the stable Port entry.
# Resolution uses its directory even when the frontend has already removed the
# temporary file.
if [ -n "${PAM_SOURCE_DIR:-}" ]; then PAM_LAUNCHER_SOURCE="$PAM_DIR/APP Manager.sh"
else PAM_LAUNCHER_SOURCE="$0"; fi
PAM_APP_ROOT="$PAM_DIR/jenny92-appmanager"
[ -n "${PAM_APP_ROOT_OVERRIDE:-}" ] && PAM_APP_ROOT="$PAM_APP_ROOT_OVERRIDE"
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

TRASH_DIR="$GAMEDIR/trash"
PLAN_FILE="$CONFDIR/plan.txt"
RESULT_FILE="$CONFDIR/result.txt"
PROGRESS_FILE="$CONFDIR/progress.tsv"
CANCEL_FILE="$CONFDIR/cancel.request"
UPDATE_CACHE_FILE="$CONFDIR/portmaster-update.tsv"
VALIDATION_RESULT_FILE="$CONFDIR/validation-result.tsv"
PORTMASTER_ACTIVE_FILE="$CONFDIR/portmaster-active.tsv"
PORTMASTER_ACTIVE_LOCK="$CONFDIR/portmaster-active.lock"
OPERATION_ACTIVE_FILE="$CONFDIR/operation-active.tsv"
OPERATION_ACTIVE_LOCK="$CONFDIR/operation-active.lock"
APPLY_HELPER="$CONFDIR/apply-helper.sh"
SIZE_FILE="$CONFDIR/sizes.tsv"
RUNTIME_METADATA="$CONFDIR/runtime-metadata.tsv"
RUNTIME_METADATA_JSON="$CONFDIR/ports.json"
DEVICE_CONFIG_DIR="$CONFDIR/device-config"
DEVICE_CONFIG_FILE="$DEVICE_CONFIG_DIR/config.json"
CONFIG_REFRESH_RESULT="$CONFDIR/config-refresh.tsv"
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
OPERATION_ACTIVE=0

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
# Ordinary file/Runtime operations use the same lifecycle contract. A second
# APP instance must not overwrite plan.txt or rescan a half-mutated SD card.
if [ -s "$OPERATION_ACTIVE_FILE" ]; then
  operation_pid=$(awk -F '\t' '$1 == "pid" {print $2; exit}' "$OPERATION_ACTIVE_FILE" 2>/dev/null || true)
  if pam_helper_pid_alive "$operation_pid" --apply-plan; then
    OPERATION_ACTIVE=1
  else
    rm -f -- "$OPERATION_ACTIVE_FILE"
    if pam_lock_acquire "$OPERATION_ACTIVE_LOCK" --apply-plan; then
      stale_operation_token="$PAM_LOCK_TOKEN"
      pam_lock_release "$OPERATION_ACTIVE_LOCK" "$stale_operation_token" || true
    fi
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
  if [ "$PORTMASTER_ACTIVE" = "0" ] && [ "$OPERATION_ACTIVE" = "0" ]; then
    for helper_source in "$0" "/proc/$$/fd/255" "$PAM_DIR/APP Manager.sh"; do
      [ -f "$helper_source" ] || continue
      [ "$helper_source" = "$APPLY_HELPER" ] && continue
      if cp -f "$helper_source" "$APPLY_HELPER" 2>/dev/null; then
        helper_ready=1
        break
      fi
    done
  fi
  if [ "$helper_ready" = "0" ] && grep -q '^apply_plan()' "$APPLY_HELPER" 2>/dev/null; then
    helper_ready=1
  fi
  if [ "$helper_ready" = "1" ]; then chmod +x "$APPLY_HELPER" 2>/dev/null
  else APPLY_HELPER=""; fi
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
  "operation_active": "$(json_escape "$OPERATION_ACTIVE_FILE")",
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

# ── Runtime repair ─────────────────────────────────────────────────────
# Runtime repair refreshes PortMaster's official release `ports.json`, the same
# metadata source used by PortMaster itself. Only a state cache is retained;
# the APP package carries no Runtime inventory.
RUNTIME_PROGRESS_COUNT=0
RUNTIME_PROGRESS_TOTAL_BYTES=0
RUNTIME_PROGRESS_RUNTIME=""
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
    "$phase" "$RUNTIME_PROGRESS_RUNTIME" 0 "$RUNTIME_PROGRESS_COUNT" \
    "$current" "$RUNTIME_PROGRESS_TOTAL_BYTES" "$speed" "$detail" > "$tmp" &&
    mv -f -- "$tmp" "$PROGRESS_FILE"
}

runtime_progress_prepare_plan() {
  local kind arg bytes
  RUNTIME_PROGRESS_COUNT=0
  RUNTIME_PROGRESS_TOTAL_BYTES=0
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
  [ -f "$RUNTIME_METADATA_JSON" ] || return 1
  "$PAM_APPMANAGER_CLI" runtime-metadata-entry --metadata "$RUNTIME_METADATA_JSON" \
    --runtime "$runtime" --arch "$arch" 2>> "$PAM_APP_ROOT/log.txt" |
    awk -F '\t' -v field="$field" 'NF == 5 { print $field; exit }'
}

runtime_expected_size() { runtime_metadata_field "$1" 3; }

runtime_metadata_refresh() {
  local force="${1:-0}"
  set -- refresh-runtime-metadata --source "$RUNTIME_METADATA_URL" \
    --json-cache "$RUNTIME_METADATA_JSON" --tsv-cache "$RUNTIME_METADATA"
  [ "$force" != 1 ] || set -- "$@" --force
  "$PAM_APPMANAGER_CLI" "$@" >/dev/null 2>> "$PAM_APP_ROOT/log.txt"
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

pam_refresh_stable_cache() {
  pam_update_allowed || return 0
  set -- refresh-stable-cache --source "$(pam_release_manifest_url)" --cache "$UPDATE_CACHE_FILE"
  [ "$FORCE_UPDATE_CHECK" != 1 ] || set -- "$@" --force
  "$PAM_APPMANAGER_CLI" "$@" >/dev/null 2>> "$PAM_APP_ROOT/log.txt"
}

pm_cancel_requested() { [ -e "$CANCEL_FILE" ]; }

pam_refresh_device_config() {
  local native_launcher timeout="${PAM_CONFIG_REFRESH_TIMEOUT_SECONDS:-40}"
  case "$timeout" in ''|*[!0-9]*) timeout=40 ;; esac
  [ "$timeout" -ge 1 ] && [ "$timeout" -le 44 ] || timeout=40
  native_launcher="${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_LAUNCHER_SOURCE}"
  case "$native_launcher" in /*) ;; *) native_launcher="$PAM_DIR/$(basename "$native_launcher")" ;; esac
  set -- config refresh --source "$PAM_DEVICE_CONFIG_URL" \
    --config "$PAM_CONFIG_DIR/config.json" --config-dir "$PAM_CONFIG_DIR" \
    --cache "$DEVICE_CONFIG_FILE" --cache-dir "$DEVICE_CONFIG_DIR" \
    --result "$CONFIG_REFRESH_RESULT" --launcher "$native_launcher" --timeout-seconds "$timeout"
  [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
  "$PAM_PORTKIT" "$@" >/dev/null 2>> "$PAM_APP_ROOT/log.txt"
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
  local cache="$CONFDIR/portmaster-download" metadata archive archive_dir rc
  local stable_url stable_version expected_hash actual_hash archive_valid=0 reason archive_name
  metadata="$cache/version.tsv"
  rm -f -- "$CANCEL_FILE"; mkdir -p "$cache" || return 1
  rm -f -- "$cache/version.json" "$metadata" "$cache/appmanager-installer.sh" "$cache/appmanager-installer.sh.new"
  RUNTIME_PROGRESS_RUNTIME="PortMaster"
  runtime_progress_write preparing 1 0 "Preparing PortMaster"
  ensure_portmaster_python_runtime || {
    printf 'FAIL\tportmaster\tpython-runtime\n' >> "$RESULT_FILE"
    return 1
  }
  pam_release_route_allowed || { printf 'FAIL\tportmaster\tcapability-disabled\n' >> "$RESULT_FILE"; return 1; }
  archive_name=$(pam_release_archive_name) || { printf 'FAIL\tportmaster\tversion-url\n' >> "$RESULT_FILE"; return 1; }
  "$PAM_APPMANAGER_CLI" fetch-stable-release --source "$(pam_release_manifest_url)" \
    --archive-name "$archive_name" --output "$metadata" >/dev/null 2>> "$PAM_APP_ROOT/log.txt" || {
      rc=$?; printf 'FAIL\tportmaster\t%s\n' "$([ -e "$CANCEL_FILE" ] && echo cancelled || echo network)" >> "$RESULT_FILE"; return 1;
    }
  IFS=$'\t' read -r stable_version stable_url expected_hash < "$metadata" || {
    printf 'FAIL\tportmaster\tversion\n' >> "$RESULT_FILE"; return 1;
  }
  archive_dir="$cache/$stable_version"; archive="$archive_dir/$archive_name"
  mkdir -p "$archive_dir" || return 1

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
  local runtime="$1" target
  target="$LIBS_DIR/$runtime.squashfs"
  [ -f "$RUNTIME_METADATA_JSON" ] || return 1
  "$PAM_APPMANAGER_CLI" runtime-metadata-entry --metadata "$RUNTIME_METADATA_JSON" \
    --runtime "$runtime" --arch "$(runtime_arch)" --image "$target" \
    >/dev/null 2>> "$PAM_APP_ROOT/log.txt"
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

pam_plan_is_file_only() {
  awk -F '\t' '
    /^[[:space:]]*($|#)/ { next }
    NF != 2 { exit 1 }
    $1 !~ /^(TRASH|DELETE_MANAGED|EMPTY_TRASH|RESTORE_TRASH|RESTORE_ITEM|DELETE_ITEM|CLEAN_APPLEDOUBLE)$/ { exit 1 }
    { found=1 }
    END { exit !found }
  ' "$PLAN_FILE" 2>/dev/null
}

pam_plan_has_file_actions() {
  awk -F '\t' '$1 ~ /^(TRASH|DELETE_MANAGED|EMPTY_TRASH|RESTORE_TRASH|RESTORE_ITEM|DELETE_ITEM|CLEAN_APPLEDOUBLE)$/ { found=1 } END { exit !found }' \
    "$PLAN_FILE" 2>/dev/null
}

pam_apply_file_plan_native() {
  local native_launcher output="$CONFDIR/apply-file-plan.$$"
  [ "$PAM_NATIVE_PROFILE_ACTIVE" = 1 ] && [ -x "$PAM_APPMANAGER_CLI" ] || return 1
  native_launcher="${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_LAUNCHER_SOURCE}"
  case "$native_launcher" in /*) ;; *) native_launcher="$PAM_DIR/$(basename "$native_launcher")" ;; esac
  set -- --config-dir "$PAM_CONFIG_DIR" apply-file-plan \
    --plan "$PLAN_FILE" \
    --result "$RESULT_FILE" \
    --size-cache "$SIZE_FILE" \
    --progress "$PROGRESS_FILE" \
    --self-launcher "$native_launcher" \
    --self-port "$PORT_NAME" \
    --launcher "$native_launcher" \
    --app-state "$CONFDIR" \
    --trash "$TRASH_DIR"
  [ -z "$ESUDO" ] || set -- "$@" --privilege-command "$ESUDO"
  [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
  [ -s "$DEVICE_CONFIG_FILE" ] && set -- "$@" --remote-config "$DEVICE_CONFIG_FILE" --remote-config-dir "$DEVICE_CONFIG_DIR"
  [ -z "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || set -- "$@" --target-override "$PAM_NATIVE_TARGET_DEVICE"
  if "$PAM_APPMANAGER_CLI" "$@" > "$output" 2>> "$PAM_APP_ROOT/log.txt"; then
    rm -f -- "$output"
    return 0
  fi
  rm -f -- "$output"
  printf 'FAIL\toperation\tnative-file-operation\n' >> "$RESULT_FILE"
  return 1
}

pam_operation_begin() {
  if ! pam_lock_acquire "$OPERATION_ACTIVE_LOCK" --apply-plan; then return 1; fi
  APPLY_OPERATION_TOKEN="$PAM_LOCK_TOKEN"
  {
    printf 'version\t1\n'
    printf 'token\t%s\n' "$APPLY_OPERATION_TOKEN"
    printf 'pid\t%s\n' "$$"
    printf 'started\t%s\n' "$(date +%s 2>/dev/null || echo 0)"
  } > "$OPERATION_ACTIVE_FILE.tmp.$$" &&
    mv -f -- "$OPERATION_ACTIVE_FILE.tmp.$$" "$OPERATION_ACTIVE_FILE" || {
      rm -f -- "$OPERATION_ACTIVE_FILE.tmp.$$"
      pam_lock_release "$OPERATION_ACTIVE_LOCK" "$APPLY_OPERATION_TOKEN" || true
      APPLY_OPERATION_TOKEN=""
      return 1
    }
}

pam_operation_end() {
  local token="${APPLY_OPERATION_TOKEN:-}"
  [ -n "$token" ] || return 1
  if [ "$(awk -F '\t' '$1 == "token" {print $2; exit}' "$OPERATION_ACTIVE_FILE" 2>/dev/null || true)" = "$token" ]; then
    rm -f -- "$OPERATION_ACTIVE_FILE"
  fi
  pam_lock_release "$OPERATION_ACTIVE_LOCK" "$token"
  APPLY_OPERATION_TOKEN=""
}

apply_plan() {
  local kind arg
  local device_risk_ack=0 device_support_ack=0 runtime_metadata_ready=1 native_runtime_handled=0
  : > "$RESULT_FILE"
  rm -f -- "$PROGRESS_FILE" "$PROGRESS_FILE.tmp.$$"
  if [ ! -f "$PLAN_FILE" ]; then
    printf 'FAIL\toperation\n' >> "$RESULT_FILE"
    return
  fi
  if pam_plan_is_file_only; then
    pam_apply_file_plan_native || true
    sync
    return
  fi
  if pam_plan_has_file_actions; then
    printf 'FAIL\toperation\tmixed-file-plan\n' >> "$RESULT_FILE"
    return
  fi
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
    runtime_progress_write complete 0 0 "Runtime repair complete"
  fi

  sync
}

pam_validate_pending_native() {
  local native_launcher output="$CONFDIR/validate-pending.$$" core_health rc
  local validation_schema validation_status validation_detail
  [ "$PAM_NATIVE_PROFILE_ACTIVE" = 1 ] && [ -x "$PAM_APPMANAGER_CLI" ] || return 1
  native_launcher="${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_LAUNCHER_SOURCE}"
  case "$native_launcher" in /*) ;; *) native_launcher="$PAM_DIR/$(basename "$native_launcher")" ;; esac
  core_health=$(pam_core_health)
  if [ "$core_health" = healthy ] && [ -z "$(pam_core_version)" ]; then core_health=damaged; fi
  set -- --config-dir "$PAM_CONFIG_DIR" validate-pending-install \
    --launcher "$native_launcher" \
    --app-state "$CONFDIR" \
    --trash "$TRASH_DIR" \
    --core-health "$core_health"
  [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
  [ -s "$DEVICE_CONFIG_FILE" ] && set -- "$@" --remote-config "$DEVICE_CONFIG_FILE" --remote-config-dir "$DEVICE_CONFIG_DIR"
  [ -z "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || set -- "$@" --target-override "$PAM_NATIVE_TARGET_DEVICE"
  [ "${PAM_TEST_INTERRUPT_VALIDATION:-0}" != 1 ] || set -- "$@" --test-interrupt-before-mutation
  case "${PAM_TEST_FAIL_RESTORE_AFTER:-0}" in
    0|"") ;;
    *[!0-9]*) return 1 ;;
    *) set -- "$@" --test-fail-restore-after "$PAM_TEST_FAIL_RESTORE_AFTER" ;;
  esac
  "$PAM_APPMANAGER_CLI" "$@" > "$output" 2>> "$PAM_APP_ROOT/log.txt"; rc=$?
  if [ "$rc" = 0 ]; then
    IFS=$'\t' read -r validation_schema validation_status validation_detail < "$VALIDATION_RESULT_FILE" || {
      validation_schema=""; validation_status="";
    }
    case "$validation_schema:$validation_status" in
      1:valid|1:none) rc=0 ;;
      1:restored|1:no-usable) rc=1 ;;
      1:interrupted|1:checking) rc=75 ;;
      *) rc=1 ;;
    esac
  fi
  rm -f -- "$output"
  return "$rc"
}

# ── 主入口 ────────────────────────────────────────────────────────────
pam_scan_sizes_native() {
  local native_launcher output="$CONFDIR/scan-sizes.$$"
  [ "$PAM_NATIVE_PROFILE_ACTIVE" = 1 ] && [ -x "$PAM_APPMANAGER_CLI" ] || return 1
  native_launcher="${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_LAUNCHER_SOURCE}"
  case "$native_launcher" in /*) ;; *) native_launcher="$PAM_DIR/$(basename "$native_launcher")" ;; esac
  set -- --config-dir "$PAM_CONFIG_DIR" scan-device-sizes \
    --output "$SIZE_FILE" \
    --self-port "$PORT_NAME" \
    --launcher "$native_launcher" \
    --app-state "$CONFDIR" \
    --trash "$TRASH_DIR"
  [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
  [ -s "$DEVICE_CONFIG_FILE" ] && set -- "$@" --remote-config "$DEVICE_CONFIG_FILE" --remote-config-dir "$DEVICE_CONFIG_DIR"
  [ -z "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || set -- "$@" --target-override "$PAM_NATIVE_TARGET_DEVICE"
  "$PAM_APPMANAGER_CLI" "$@" > "$output" 2>> "$PAM_APP_ROOT/log.txt" || {
    rm -f -- "$output"
    return 1
  }
  rm -f -- "$output"
}

if [ "$SIZE_ONLY" = "1" ]; then
  pam_scan_sizes_native
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
  pam_write_native_install_plan "$install_plan" || exit 1
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
  pam_refresh_stable_cache
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
  pam_validate_pending_native
  rc=$?
  write_env
  exit "$rc"
fi

if [ "$APPLY_ONLY" != "1" ] && [ "$OPERATION_ACTIVE" = "0" ]; then
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
  # One helper owns plan.txt, result.txt and inventory publication from start
  # to finish. A restarted UI observes operation-active.tsv instead of starting
  # another worker against the same SD card.
  pam_operation_begin || exit 75
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
  pam_operation_end || true
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
    echo "$LOG_PREFIX APP Manager UI runtime is missing"
    return 1
  fi
  export LOVE_IDENTITY="port_app_manager"
  export LOVE_WINDOW_TITLE="Port App Manager"
  export LOVE_FONT_PATH SDL_GAMECONTROLLERCONFIG_FILE SSL_CERT_FILE CURL_CA_BUNDLE
  # Static pages redraw slowly to save CPU; visible animations temporarily use
  # the smooth rate and automatically fall back when they finish.
  export LOVE_LITE_FPS=6
  export LOVE_LITE_ANIMATION_FPS=60
  export LOVE_LITE_RENDERER=auto
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
      --set "PAM_SOURCE_DIR=$PAM_DIR"
    [ -z "${PAM_NATIVE_ROOT:-}" ] || set -- "$@" --root "$PAM_NATIVE_ROOT"
    [ -s "$DEVICE_CONFIG_FILE" ] && set -- "$@" --remote-config "$DEVICE_CONFIG_FILE" --remote-config-dir "$DEVICE_CONFIG_DIR"
    [ -z "${PAM_PORTMASTER_DIR_OVERRIDE:-}" ] || set -- "$@" --target-override "$PAM_NATIVE_TARGET_DEVICE"
    set -- "$@" -- "$PAM_APP_ROOT/runtime/love.aarch64" "$PAM_APP_ROOT/love_ui" "$DISPLAY_WIDTH" "$DISPLAY_HEIGHT"
    "$PAM_PORTKIT" "$@" &
  else
    "$PAM_APP_ROOT/runtime/love.aarch64" "$PAM_APP_ROOT/love_ui" "$DISPLAY_WIDTH" "$DISPLAY_HEIGHT" &
  fi
  love_pid=$!
  wait "$love_pid"; exit_code=$?
  if [ "$key_pid" != "0" ]; then kill "$key_pid" 2>/dev/null; wait "$key_pid" 2>/dev/null || true; fi
  return "$exit_code"
}

run_portable_ui || true
pm_finish
exit 0
