#!/bin/bash
# PORTMASTER: appmanager, APP Manager.sh
#
# APP Manager — PortMaster 端口管理器。
#
# 这个 port 刻意做到零外部 runtime 依赖: 它自带 runtime/frt_3.6.squashfs 并挂
# 自己那一份来跑 UI, 完全不依赖 PortMaster libs/ 里有什么。这不是洁癖 —— 这个
# APP 的职责之一就是修复 Jenny 移植游戏的设置启动器。如果它自己得先有外部
# runtime 才能启动，那在最需要修复的机器上它恰好起不来。同一个 squashfs 同时
# 作为内部修复组件；这些实现名不展示给普通用户。
#
# 删除动作全部在这里执行, 不在 Godot 里: 卡是 exFAT 以 uid=0 挂的, Godot 作为
# 子进程拿不到 root。UI 写 plan.txt 后调用本脚本的 --apply-plan 模式，用 $ESUDO
# 落地；FRT 不退出，完成后只让 UI 重新扫描并刷新列表。

PORT_NAME="appmanager"; LOG_PREFIX="[PAM]"
BUNDLED_RT="frt_3.6"
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
XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "$PAM_DIR/PortMaster/" ]; then controlfolder="$PAM_DIR/PortMaster"
elif [ -d "/opt/system/Tools/PortMaster/" ]; then controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then controlfolder="$XDG_DATA_HOME/PortMaster"
else controlfolder="/roms/ports/PortMaster"
fi
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

# ── 环境 → env.json (GDScript 侧的唯一事实来源) ──────────────────────────
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
  "bundled_runtime": "$BUNDLED_RT",
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
  "ignore_dirs": ["PortMaster", "images", "$PORT_NAME"],
  "ignore_scripts": ["PortMaster.sh", "$(basename "$PAM_LAUNCHER_SOURCE")", ".port.sh"],
  "self_port": "$PORT_NAME"
}
EOF
}

# ── frt: 先用自带的, 没有才回落到 PortMaster libs/ ───────────────────────
FRT_MNT="$GAMEDIR/frt_rt"
frt_mount() {
  local squash=""
  if [ -f "$GAMEDIR/runtime/${BUNDLED_RT}.squashfs" ]; then
    squash="$GAMEDIR/runtime/${BUNDLED_RT}.squashfs"
    FRT_NAME="$BUNDLED_RT"
  else
    squash=$(ls "$LIBS_DIR"/frt_3.*.squashfs 2>/dev/null | sort -V | tail -1)
    [ -z "$squash" ] && return 1
    FRT_NAME="$(basename "$squash" .squashfs)"
  fi
  mkdir -p "$FRT_MNT"
  $ESUDO umount "$FRT_MNT" 2>/dev/null
  $ESUDO mount "$squash" "$FRT_MNT" || return 1
  FRT_BIN="$FRT_MNT/$FRT_NAME"
  [ -x "$FRT_BIN" ] || return 1
  echo "$LOG_PREFIX frt: $squash -> $FRT_BIN"
  return 0
}

frt_umount() {
  $ESUDO umount "$FRT_MNT" 2>/dev/null
}

run_ui() {
  export FRT_NO_EXIT_SHORTCUTS=FRT_NO_EXIT_SHORTCUTS
  export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
  export PAM_ENV="$CONFDIR/env.json"
  export PAM_SOURCE_DIR="$PAM_DIR"
  $GPTOKEYB "$FRT_NAME" -c "$GAMEDIR/${PORT_NAME}.gptk" &
  local gptokeyb_pid=$!
  pm_platform_helper "$FRT_NAME"
  LD_PRELOAD="$GAMEDIR/hacksdl/hacksdl.aarch64.so" HACKSDL_DEVICE_DISABLE_0=2 \
  XDG_CONFIG_HOME="$CONFDIR" XDG_DATA_HOME="$CONFDIR" \
  GODOT_SILENCE_ROOT_WARNING=1 \
    "$FRT_BIN" --resolution "${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}" \
    --main-pack "$GAMEDIR/bootstrap.pck"
  ui_exit=$?
  kill $gptokeyb_pid 2>/dev/null; wait $gptokeyb_pid 2>/dev/null
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

      TRASH)
        # UI 只能移动三个受管根目录的直接子项。即使 plan.txt 损坏，也不能让提权的
        # shell 把任意路径移走；本 APP、PortMaster 和临时 .port.sh 再额外挡一次。
        base=$(basename "$arg")
        if ! { [ "$(dirname "$arg")" = "$SCRIPTS_DIR" ] && [[ "$base" = *.sh ]] ||
               { [ -n "$IMAGES_DIR" ] && [ "$(dirname "$arg")" = "$IMAGES_DIR" ]; } ||
               [ "$(dirname "$arg")" = "$GAMEDIRS_DIR" ]; } ||
           [ "$arg" = "$GAMEDIR" ] ||
           [ "$arg" = "$PAM_DIR/$(basename "$0")" ] ||
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

      INSTALL_RT)
        if [ "$arg" != "$BUNDLED_RT" ]; then
          printf 'FAIL\toperation\n' >> "$RESULT_FILE"
          echo "$LOG_PREFIX rejected repair component: $arg"
          continue
        fi
        local src="$GAMEDIR/runtime/${arg}.squashfs"
        if [ ! -f "$src" ]; then
          printf 'FAIL\trepair_files\n' >> "$RESULT_FILE"
          continue
        fi
        $ESUDO mkdir -p "$LIBS_DIR"
        if $ESUDO cp -f "$src" "$LIBS_DIR/${arg}.squashfs"; then
          echo "$LOG_PREFIX launcher repair complete"
        else
          printf 'FAIL\trepair\n' >> "$RESULT_FILE"
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

      *)
        printf 'FAIL\toperation\n' >> "$RESULT_FILE"
        echo "$LOG_PREFIX unknown action: $kind"
        ;;
    esac
  done < "$PLAN_FILE"

  $ESUDO rm -f "$PLAN_FILE"
  sync
}

# ── 主入口 ────────────────────────────────────────────────────────────
# 容量统计会递归读整个游戏目录，绝不能放在 Godot 渲染线程。
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
  exit 0
fi

if ! frt_mount; then
  echo "$LOG_PREFIX 找不到可用的 frt 运行时, 退出"
  exit 1
fi

while true; do
  run_ui
  echo "$LOG_PREFIX ui_exit=$ui_exit"
  [ "$ui_exit" = "42" ] || break
  apply_plan
  write_env          # 空间/目录都变了, 重新采一次
done

frt_umount
[ -n "$(command -v pm_finish)" ] && pm_finish
exit 0
