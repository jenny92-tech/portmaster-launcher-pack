#!/bin/bash
# PORTMASTER: appmanager, APP Manager.sh
#
# APP Manager — PortMaster 端口管理器。
#
# UI uses PortMaster's system LÖVE 11.5 runtime, the same guaranteed runtime used
# by every migrated Jenny launcher. Safety-critical filesystem mutations remain
# in this shell and are never performed directly by Lua.
#
# UI writes plan.txt and invokes this script's --apply-plan mode. The helper
# re-validates every path under $ESUDO, then the running LÖVE UI rescans.

PORT_NAME="appmanager"; LOG_PREFIX="[PAM]"
APPLY_ONLY=0
SIZE_ONLY=0
case "${1:-}" in
  --apply-plan) APPLY_ONLY=1 ;;
  --scan-sizes) SIZE_ONLY=1 ;;
esac

# ── PortMaster preamble (controlfolder 发现 + control.txt) ────────────────
# 标准那套探测(/opt/system/Tools/... /roms/ports/...)在 MiniLoong 上全落空 ——
# 它的 PortMaster 在 /mnt/sdcard/roms/ports/PortMaster。与其再硬编码一个绝对
# 路径, 不如认一个更强的事实: 当前启动脚本就躺在 ports 目录里, PortMaster/
# 就在它旁边。MiniLoong 会把目标 SH 重命名为 .port.sh 后直接执行，此时 $0
# 就是真实正在运行的启动脚本。
#
# 变量名必须是私有的: PortMaster 的 control.txt 自己也用 SCRIPT_DIR, source 之后
# 会把它清空 —— 用通用名字在这里必然被踩掉(实测 [$SCRIPT_DIR] -> [])。
PAM_DIR="${PAM_SOURCE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
PAM_LAUNCHER_SOURCE="$0"
#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/portmaster_bootstrap.sh"
#@KIT-END
portmaster_discover "$PAM_DIR"
source "$controlfolder/control.txt"
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
# get_controls 是启动 UI 时的平台初始化，不是“取变量”。部分固件
# (吹米 TrimUI) 会在里面用 sdl2imgshow 显示启动图，再 pkill 关掉。
# 后台 helper 若重跑它，每次删除/恢复就会精确地闪两下。
if [ "$APPLY_ONLY" != "1" ] && [ "$SIZE_ONLY" != "1" ]; then
  get_controls
fi

# 脚本目录和游戏目录不一定是同一个。PortMaster 的 shell 侧只导出 $directory 和
# $controlfolder —— "脚本放哪"这个知识只存在于它 Python 侧的 HM_SCRIPTS_DIR, bash
# 拿不到。而各固件确实不一样(实测):
#   迷你龙/多数  gamedirs=/$directory/ports          scripts=同上
#   吹米 TrimUI  gamedirs=/mnt/SDCARD/Data/ports     scripts=/mnt/SDCARD/Roms/PORTS
#   muOS         gamedirs=/mnt/mmc/ports             scripts=/mnt/mmc/ROMS/Ports
#   ROCKNIX      gamedirs=/storage/roms/ports        scripts=/storage/roms/ports_scripts
# 所以脚本目录不去查任何配置, 直接认最强的事实: 本脚本自己就躺在脚本目录里。
SCRIPTS_DIR="$PAM_DIR"
GAMEDIRS_DIR="/$directory/ports"
GAMEDIR="$GAMEDIRS_DIR/$PORT_NAME"
CONFDIR="$GAMEDIR/conf"
LIBS_DIR="$controlfolder/libs"

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
APPLY_HELPER="$CONFDIR/apply-helper.sh"
SIZE_FILE="$CONFDIR/sizes.tsv"
RUNTIME_CATALOG="$GAMEDIR/love_ui/runtime_catalog.tsv"
RUNTIME_SOURCE_REF="0d9880ec45269e5dd6df11e5949f07005d5108d8"
RUNTIME_DIRECT_BASE="https://raw.githubusercontent.com/PortsMaster/PortMaster-New/$RUNTIME_SOURCE_REF/runtimes"

cd "$GAMEDIR" || exit 1
if [ "$APPLY_ONLY" = "1" ] || [ "$SIZE_ONLY" = "1" ]; then
  exec >> "$GAMEDIR/log.txt" 2>&1
else
  exec > "$GAMEDIR/log.txt" 2>&1
fi
mkdir -p "$CONFDIR" "$TRASH_DIR"
if [ "$APPLY_ONLY" != "1" ] && [ "$SIZE_ONLY" != "1" ]; then
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
echo "$LOG_PREFIX CFW=$CFW_NAME ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} scripts=$SCRIPTS_DIR gamedirs=$GAMEDIRS_DIR"

# Shared LÖVE runtime/font/display/input helpers are inlined for device builds.
#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/portmaster_common.sh"
#@KIT-END

# ── 环境 → env.json (LÖVE UI 的唯一事实来源) ───────────────────────────
# $directory / $controlfolder 只有 shell 知道 (control.txt 注入), 而扫描器必须
# 拿它们去展开脚本里的 GAMEDIR="/$directory/ports/$PORT_NAME"。喂不进去, 一半
# 的脚本就解析不出目录。
write_env() {
  # busybox 的 df 不认 -B1 (吹米上实测吐空), 用可移植的 -k 再乘回去。
  local free
  free=$(df -k "$SCRIPTS_DIR" 2>/dev/null | awk 'NR==2 {print $4 * 1024}')
  case "$free" in ''|*[!0-9]*) free=0 ;; esac
  cat > "$CONFDIR/env.json" <<EOF
{
  "controlfolder": "$controlfolder",
  "scripts_dir": "$SCRIPTS_DIR",
  "gamedirs_dir": "$GAMEDIRS_DIR",
  "images_dir": "$IMAGES_DIR",
  "libs_dir": "$LIBS_DIR",
  "gamedir": "$GAMEDIR",
  "directory": "$directory",
  "home": "$HOME",
  "cfw": "$CFW_NAME",
  "free_bytes": $free,
  "display_width": "${DISPLAY_WIDTH:-}",
  "display_height": "${DISPLAY_HEIGHT:-}",
  "device_arch": "${DEVICE_ARCH:-}",
  "device": "${DEVICE:-}",
  "param_device": "${param_device:-}",
  "analog_sticks": "${ANALOGSTICKS:-}",
  "lowres": "${LOWRES:-}",
  "cur_tty": "${CUR_TTY:-}",
  "sdl_controller_file": "${SDL_GAMECONTROLLERCONFIG_FILE:-}",
  "esudo": "${ESUDO:-}",
  "gptokeyb": "${GPTOKEYB:-}",
  "path": "${PATH:-}",
  "ld_library_path": "${LD_LIBRARY_PATH:-}",
  "xdg_config_home": "${XDG_CONFIG_HOME:-}",
  "xdg_data_home": "${XDG_DATA_HOME:-}",
  "plan_file": "$PLAN_FILE",
  "result_file": "$RESULT_FILE",
  "apply_script": "$APPLY_HELPER",
  "size_file": "$SIZE_FILE",
  "runtime_catalog_file": "$RUNTIME_CATALOG",
  "ignore_dirs": ["PortMaster", "images", "$PORT_NAME"],
  "ignore_scripts": ["PortMaster.sh", "$(basename "$PAM_LAUNCHER_SOURCE")", ".port.sh"],
  "self_port": "$PORT_NAME"
}
EOF
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

runtime_url() {
  local proxy="$1" source="$2"
  if [ "$proxy" = "DIRECT" ]; then
    printf '%s/%s\n' "$RUNTIME_DIRECT_BASE" "$source"
  else
    printf '%s/https://github.com/PortsMaster/PortMaster-New/raw/%s/runtimes/%s\n' \
      "${proxy%/}" "$RUNTIME_SOURCE_REF" "$source"
  fi
}

runtime_has_magic() {
  [ -f "$1" ] && [ "$(LC_ALL=C head -c 4 "$1" 2>/dev/null)" = "hsqs" ]
}

runtime_prepare_downloader() {
  local candidate tool_dir tool_tmp
  [ -z "${RUNTIME_DOWNLOADER:-}" ] || return 0
  candidate="$CONFDIR/runtime-tools/curl"
  if [ -z "${PAM_RUNTIME_WGET:-}" ] && [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
    RUNTIME_CURL="$candidate"
    RUNTIME_DOWNLOADER="curl"
    return 0
  fi
  candidate=$(command -v curl 2>/dev/null || true)
  if [ -z "${PAM_RUNTIME_WGET:-}" ] && [ -n "$candidate" ] && [ -x "$candidate" ] &&
     "$candidate" --version >/dev/null 2>&1; then
    RUNTIME_CURL="$candidate"
    RUNTIME_DOWNLOADER="curl"
    return 0
  fi

  candidate="${PAM_RUNTIME_WGET:-}"
  # LoongOS ships an HTTPS-enabled GNU Wget in its PortMaster recovery assets,
  # but some firmware images lose the executable bit. Copy it into APP-owned
  # conf instead of modifying the read-only/system copy. BusyBox wget remains
  # the generic fallback on systems where it supports HTTPS itself.
  if [ -z "$candidate" ] && [ -r /oem/loong/recover/userdata/app/portmaster/wget ]; then
    candidate=/oem/loong/recover/userdata/app/portmaster/wget
  fi
  if [ -z "$candidate" ]; then candidate=$(command -v wget 2>/dev/null || true); fi
  [ -n "$candidate" ] && [ -f "$candidate" ] || return 1
  if [ ! -x "$candidate" ]; then
    tool_dir="$CONFDIR/runtime-tools"
    [ ! -L "$tool_dir" ] || return 1
    mkdir -p "$tool_dir" || return 1
    [ ! -L "$tool_dir/wget" ] || rm -f -- "$tool_dir/wget" || return 1
    tool_tmp="$tool_dir/.wget.$$"
    rm -f -- "$tool_tmp"
    cp -- "$candidate" "$tool_tmp" && chmod 0700 "$tool_tmp" && mv -f -- "$tool_tmp" "$tool_dir/wget" || {
      rm -f -- "$tool_tmp"
      return 1
    }
    candidate="$tool_dir/wget"
  fi
  [ -x "$candidate" ] || return 1
  RUNTIME_WGET="$candidate"
  RUNTIME_DOWNLOADER="wget"
}

runtime_probe_url() {
  local url="$1" out="$2"
  : > "$out" || return 1
  runtime_prepare_downloader || return 1
  if [ "$RUNTIME_DOWNLOADER" = "curl" ]; then
    "$RUNTIME_CURL" -fsSL --connect-timeout 3 --max-time 5 --range 0-3 "$url" 2>/dev/null | head -c 4 > "$out"
  elif [ "$RUNTIME_DOWNLOADER" = "wget" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout 5 "$RUNTIME_WGET" -q -O - --header='Range: bytes=0-3' "$url" 2>/dev/null | head -c 4 > "$out"
    else
      "$RUNTIME_WGET" -q -T 5 -O - --header='Range: bytes=0-3' "$url" 2>/dev/null | head -c 4 > "$out"
    fi
  else
    return 1
  fi
  runtime_has_magic "$out"
}

runtime_fetch_url() {
  local url="$1" out="$2" resume="${3:-0}"
  runtime_prepare_downloader || return 1
  if [ "$RUNTIME_DOWNLOADER" = "curl" ]; then
    if [ "$resume" = "1" ]; then
      "$RUNTIME_CURL" -fL --connect-timeout 8 --retry 2 --retry-delay 1 -C - -o "$out" "$url"
    else
      "$RUNTIME_CURL" -fL --connect-timeout 8 --retry 2 --retry-delay 1 -o "$out" "$url"
    fi
  elif [ "$RUNTIME_DOWNLOADER" = "wget" ]; then
    if [ "$resume" = "1" ]; then
      "$RUNTIME_WGET" -c -O "$out" "$url"
    else
      "$RUNTIME_WGET" -O "$out" "$url"
    fi
  else
    return 1
  fi
}

runtime_file_size() {
  [ -f "$1" ] || { echo 0; return; }
  wc -c < "$1" | tr -d '[:space:]'
}

# Adapted from NapCat-Mac-Installer's GitHubProxy.auto: all candidates probe a
# small byte range concurrently and the first verified SquashFS response wins.
# Native GitHub is verified and used when every proxy fails.
runtime_select_proxy() {
  local sample="$1" probe_root proxy id
  runtime_valid_source "$sample" || return 1
  runtime_prepare_downloader || return 1
  probe_root="$CONFDIR/proxy-probe.$$"
  rm -rf "$probe_root"; mkdir -p "$probe_root" || return 1
  RUNTIME_PROXIES="${PAM_RUNTIME_PROXIES:-https://gh.h233.eu.org
https://rapidgit.jjda.de5.net
https://gh.ddlc.top
https://gh-proxy.org
https://cdn.gh-proxy.org
https://edgeone.gh-proxy.org
https://ghproxy.it
https://github.boki.moe
https://gh-proxy.net
https://gh.jasonzeng.dev
https://gh.monlor.com
https://fastgit.cc
https://github.tbedu.top
https://firewall.lxstd.org
https://github.ednovas.xyz
https://ghfile.geekertao.top
https://ghp.keleyaa.com
https://gh.chjina.com
https://cdn.crashmc.com
https://git.yylx.win
https://gitproxy.mrhjx.cn
https://ghfast.top
https://wget.la
https://hk.gh-proxy.org}"
  id=0
  while IFS= read -r proxy; do
    [ -n "$proxy" ] || continue
    id=$((id + 1))
    (
      if runtime_probe_url "$(runtime_url "$proxy" "$sample")" "$probe_root/probe.$id"; then
        if mkdir "$probe_root/winner.lock" 2>/dev/null; then
          printf '%s\n' "$proxy" > "$probe_root/winner"
        fi
      fi
    ) &
  done <<< "$RUNTIME_PROXIES"
  wait

  if [ -s "$probe_root/winner" ]; then
    RUNTIME_PROXY=$(cat "$probe_root/winner")
    RUNTIME_PROXY_NAME="${RUNTIME_PROXY#*://}"
  elif runtime_probe_url "$(runtime_url DIRECT "$sample")" "$probe_root/direct"; then
    RUNTIME_PROXY="DIRECT"
    RUNTIME_PROXY_NAME="GitHub"
  else
    rm -rf "$probe_root"
    return 1
  fi
  echo "$LOG_PREFIX Runtime source selected: $RUNTIME_PROXY_NAME"
  rm -rf "$probe_root"
  RUNTIME_PROXY_READY=1
}

runtime_download_source() {
  local source="$1" expected="$2" out="$3" candidate url seen_direct=0 actual rc
  case "$expected" in ""|*[!0-9]*|0) return 1 ;; esac
  if [ -L "$out" ]; then rm -f -- "$out" || return 1; fi
  actual=$(runtime_file_size "$out")
  if [ "$actual" = "$expected" ]; then
    echo "$LOG_PREFIX using complete Runtime cache: $source"
    [ -n "${RUNTIME_DOWNLOAD_VIA:-}" ] || RUNTIME_DOWNLOAD_VIA="Cache"
    return 0
  fi
  if [ "$actual" -gt "$expected" ]; then
    echo "$LOG_PREFIX discarding oversized Runtime cache: $source"
    rm -f -- "$out" || return 1
    actual=0
  elif [ "$actual" -gt 0 ]; then
    echo "$LOG_PREFIX resuming $source from $actual of $expected bytes"
  fi

  for candidate in "$RUNTIME_PROXY" DIRECT; do
    if [ "$candidate" = "DIRECT" ]; then
      [ "$seen_direct" = "0" ] || continue
      seen_direct=1
    fi
    url=$(runtime_url "$candidate" "$source")
    echo "$LOG_PREFIX downloading $source via $([ "$candidate" = DIRECT ] && echo GitHub || echo "${candidate#*://}")"
    actual=$(runtime_file_size "$out")
    rc=0
    if [ "$actual" -gt 0 ]; then
      runtime_fetch_url "$url" "$out" 1 || rc=$?
    else
      runtime_fetch_url "$url" "$out" 0 || rc=$?
    fi
    actual=$(runtime_file_size "$out")
    if [ "$rc" = "0" ] && [ "$actual" = "$expected" ]; then
      RUNTIME_DOWNLOAD_VIA="$([ "$candidate" = DIRECT ] && echo GitHub || echo "${candidate#*://}")"
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
        RUNTIME_DOWNLOAD_VIA="$([ "$candidate" = DIRECT ] && echo GitHub || echo "${candidate#*://}")"
        return 0
      fi
      [ "$actual" -le "$expected" ] || rm -f -- "$out"
    fi
  done
  return 1
}

install_runtime() {
  local runtime="$1" sources source_sizes expected_size actual_size work combined part source source_size target staged cache_root cache_ref cache_dir index
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
  done
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
  local stamp kind arg dest base bucket batch item trash_failed=0 empty_failed=0
  stamp=$(date +%Y%m%d-%H%M%S)
  : > "$RESULT_FILE"
  if [ ! -f "$PLAN_FILE" ]; then
    printf 'FAIL\toperation\n' >> "$RESULT_FILE"
    return
  fi

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
        install_runtime "$arg" || true
        ;;

      *)
        printf 'FAIL\toperation\n' >> "$RESULT_FILE"
        echo "$LOG_PREFIX unknown action: $kind"
        ;;
    esac
  done < "$PLAN_FILE"

  sync
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

write_env
if [ "$APPLY_ONLY" = "1" ]; then
  apply_plan
  write_env          # 空间、Runtime 和目录状态都可能变化
  # plan.txt is the UI's completion signal. Remove it only after env.json is
  # fully refreshed, otherwise the renderer can race a partially-written file.
  $ESUDO rm -f "$PLAN_FILE"
  exit 0
fi

export PAM_ENV="$CONFDIR/env.json"
export PAM_SOURCE_DIR="$PAM_DIR"
run_love_launcher_ui "$GAMEDIR/love_ui"
[ -n "$(command -v pm_finish)" ] && pm_finish
exit 0
