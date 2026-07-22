#!/usr/bin/env bash
set -euo pipefail
export PAM_TOOL_MODE=system # Host fixtures run on macOS, not the packaged aarch64 runtime.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO_ROOT=$(cd "$ROOT/../.." && pwd)
bash "$REPO_ROOT/_kit/dist_port.sh" appmanager >/dev/null
cargo build --quiet --manifest-path "$REPO_ROOT/Cargo.toml" -p appmanager-cli -p portkit-cli
HOST_PORTKIT="$REPO_ROOT/target/debug/portkit"
HOST_APPMANAGER="$REPO_ROOT/target/debug/appmanager-cli"
LAUNCHER="$ROOT/dist/APP Manager.sh"
APP_UI_DIR="$ROOT/love"
TMP=$(mktemp -d)
cleanup() {
  local rc=$?
  if [ "$rc" != 0 ]; then
    echo "failed mode: ${CURRENT_MODE:-unknown}" >&2
    find "$TMP/${CURRENT_MODE:-}" \( -name log.txt -o -name result.txt \) -type f 2>/dev/null | while read -r file; do
      echo "--- $file" >&2; sed -n '1,220p' "$file" >&2
    done
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

# helper must remain asynchronous so the LÖVE render loop stays responsive.
grep -Fq ' --apply-plan >/dev/null 2>&1 &' "$APP_UI_DIR/app_operations.lua"
grep -Fq 'if not model.file_exists(env.plan_file)' "$APP_UI_DIR/main.lua"
grep -Fq ' --scan-sizes >/dev/null 2>&1 &' "$APP_UI_DIR/main.lua"
grep -Fq 'not model.file_exists(env.size_file)' "$APP_UI_DIR/main.lua"
! grep -Fq ' --refresh-runtime-metadata >/dev/null 2>&1 &' "$APP_UI_DIR/main.lua"
grep -Fq 'function self.request_cached' "$APP_UI_DIR/app_model.lua"
grep -Fq 'function self.invalidate_for_plan' "$APP_UI_DIR/app_model.lua"
grep -Fq 'model.invalidate_for_plan' "$APP_UI_DIR/app_operations.lua"
grep -Fq 'task.timeout_notified=true' "$APP_UI_DIR/main.lua"
grep -Fq 'elseif task.timeout_notified then' "$APP_UI_DIR/main.lua"
grep -Fq 'size_cache_apply_mutations' "$LAUNCHER"
! sed -n '/^apply_plan()/,/^pending_value()/p' "$LAUNCHER" | grep -Fq 'scan_sizes'
grep -Fq 'pam_zip_readable "$PAM_PORTMASTER_DIR/pylibs.zip"' "$LAUNCHER"
! grep -Fq 'model.refresh_scan()' "$APP_UI_DIR/main.lua"
grep -Fq 'trash_action("DELETE_ITEM"' "$APP_UI_DIR/app_pages.lua"
grep -Fq 'item.kind="DELETE_MANAGED"' "$APP_UI_DIR/app_pages.lua"
grep -Fq 'env.progress_file' "$APP_UI_DIR/app_operations.lua"
grep -Fq 'Clean ._Files garbage files' "$APP_UI_DIR/app_pages.lua"
! grep -Fq 'github_proxy_' "$LAUNCHER"
grep -Fq 'github fetch --capability release' "$LAUNCHER"
grep -Fq 'fetch-runtime-metadata' "$LAUNCHER"
grep -Fq '正在检查网络' "$APP_UI_DIR/app_model.lua"
grep -Fq '连接已就绪，正在使用' "$APP_UI_DIR/app_model.lua"
if grep -Eq 'githubfast\.com|gitclone\.com' "$LAUNCHER"; then
  echo "unusable Git clone-only/403 services must not be Runtime candidates" >&2
  exit 1
fi
if grep -R -Fq 'os.execute(shquote(env.apply_script).." --apply-plan")' "$APP_UI_DIR"; then
  echo "appmanager helper must not block the render thread" >&2
  exit 1
fi

make_case() {
  local mode=$1
  CURRENT_MODE=$mode
  local case_dir="$TMP/$1"
  local scripts="$case_dir/scripts"
  local card="$case_dir/card"
  local gamedirs="$card/ports"
  [ "$mode" != "same_root_delete" ] || scripts="$gamedirs"
  local app="$gamedirs/appmanager"
  mkdir -p "$scripts/PortMaster/libs" "$scripts/PortMaster/runtimes/love_11.5" \
    "$scripts/images" "$gamedirs/GameData" "$app/conf" "$app/trash" "$app/love_ui" \
    "$app/runtime/libs.aarch64" "$app/bin" "$app/share" "$case_dir/bin"
  cp -R "$REPO_ROOT/config" "$app/config"
  cp "$LAUNCHER" "$scripts/APP Manager.sh"
  : > "$app/love_ui/main.lua"
  cp "$ROOT/love/json.lua" "$app/love_ui/json.lua"
  : > "$app/love_ui/ui.gptk"
  : > "$scripts/Game.sh"

  cat > "$scripts/PortMaster/control.txt" <<EOF
directory="${card#/}"
CFW_NAME="test"
DISPLAY_WIDTH=854
DISPLAY_HEIGHT=480
DEVICE_ARCH=aarch64
DEVICE=test-controller
param_device=test-device
ANALOGSTICKS=2
LOWRES=N
CUR_TTY=/dev/tty0
SDL_GAMECONTROLLERCONFIG_FILE=/tmp/test-gamecontrollerdb.txt
ESUDO="$case_dir/mock-sudo"
GPTOKEYB=/bin/true
sdl_controllerconfig=""
get_controls() {
  count=0
  [ ! -f "\$TEST_CONTROL_COUNT" ] || count=\$(cat "\$TEST_CONTROL_COUNT")
  count=\$((count + 1))
  printf '%s\n' "\$count" > "\$TEST_CONTROL_COUNT"
  if [ "\${TEST_MODE:-}" = "helper_fallback" ]; then
    rm -f -- "\$TEST_RUNNING_SOURCE"
  fi
}
pm_platform_helper() { :; }
pm_finish() { :; }
EOF

  cat > "$scripts/PortMaster/runtimes/love_11.5/love.txt" <<'EOF'
LOVE_GPTK=love.aarch64
LOVE_RUN="$controlfolder/runtimes/love_11.5/love.aarch64"
EOF
cat > "$scripts/PortMaster/runtimes/love_11.5/love.aarch64" <<'LOVE'
#!/usr/bin/env bash
set -e
count=0
[ ! -f "$TEST_COUNT" ] || count=$(cat "$TEST_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$TEST_COUNT"
[ "$count" = "1" ] || exit 0
case "$TEST_MODE" in
  delete|same_root_delete|sibling_delete)
    printf '# test plan\nTRASH\t%s\nTRASH\t%s\nTRASH\t%s\n' "$TEST_SCRIPT" "$TEST_IMAGE" "$TEST_GAME" > "$TEST_PLAN" ;;
  direct_delete|direct_delete_fail)
    printf '# test plan\nDELETE_MANAGED\t%s\nDELETE_MANAGED\t%s\nDELETE_MANAGED\t%s\n' "$TEST_SCRIPT" "$TEST_IMAGE" "$TEST_GAME" > "$TEST_PLAN" ;;
  direct_delete_invalid) printf '# test plan\nDELETE_MANAGED\t%s\n' "$TEST_OUTSIDE" > "$TEST_PLAN" ;;
  direct_delete_self) printf '# test plan\nDELETE_MANAGED\t%s\n' "$TEST_SELF" > "$TEST_PLAN" ;;
  fail)
    printf '# test plan\nTRASH\t%s\nTRASH\t%s\n' "$TEST_SCRIPT" "$TEST_GAME" > "$TEST_PLAN" ;;
  empty|empty_fail) printf '# test plan\nEMPTY_TRASH\t-\n' > "$TEST_PLAN" ;;
  appledouble) printf '# test plan\nCLEAN_APPLEDOUBLE\t-\n' > "$TEST_PLAN" ;;
  restore|sibling_restore|restore_legacy|restore_conflict|restore_fail) printf '# test plan\nRESTORE_TRASH\t-\n' > "$TEST_PLAN" ;;
  restore_selected)
    printf '# test plan\nRESTORE_ITEM\t%s\nRESTORE_ITEM\t%s\n' "$TEST_SELECTED_ITEM" "$TEST_SELECTED_IMAGE" > "$TEST_PLAN" ;;
  restore_misbucket) printf '# test plan\nRESTORE_ITEM\t%s\n' "$TEST_SELECTED_ITEM" > "$TEST_PLAN" ;;
  delete_selected)
    printf '# test plan\nDELETE_ITEM\t%s\nDELETE_ITEM\t%s\n' "$TEST_SELECTED_ITEM" "$TEST_SELECTED_IMAGE" > "$TEST_PLAN" ;;
  delete_selected_invalid) printf '# test plan\nDELETE_ITEM\t%s\n' "$TEST_SELECTED_ITEM" > "$TEST_PLAN" ;;
  delete_container_invalid)
    printf '# test plan\nDELETE_ITEM\t%s\nDELETE_ITEM\t%s\n' "$TEST_BATCH_ROOT" "$TEST_BUCKET_ROOT" > "$TEST_PLAN" ;;
  restore_selected_invalid) printf '# test plan\nRESTORE_ITEM\t%s\n' "$TEST_SELECTED_ITEM" > "$TEST_PLAN" ;;
  invalid) printf '# test plan\nTRASH\t%s\n' "$TEST_OUTSIDE" > "$TEST_PLAN" ;;
  no_plan) ;;
esac
[ "$TEST_MODE" != "renamed_launcher" ] || exit 0
[ "$TEST_MODE" != "helper_fallback" ] || rm -f -- "$TEST_RUNNING_SOURCE"
bash "$TEST_APPLY_HELPER" --apply-plan
exit 0
LOVE
  chmod +x "$scripts/PortMaster/runtimes/love_11.5/love.aarch64"
  cp "$scripts/PortMaster/runtimes/love_11.5/love.aarch64" "$app/runtime/love.aarch64"
  cp /usr/bin/true "$app/bin/gptokeyb"
  : > "$app/share/gamecontrollerdb.txt"
  : > "$app/share/cacert.pem"
  : > "$app/share/NotoSansSC-Regular.ttf"

  cat > "$case_dir/mock-sudo" <<'EOF'
#!/usr/bin/env bash
set -e
case "$1" in
  mv)
    if [ "${TEST_MODE:-}" = "fail" ] && printf '%s\n' "$*" | grep -Fq -- "$TEST_SCRIPT"; then
      exit 1
    fi
    if [ "${TEST_MODE:-}" = "restore_fail" ] && printf '%s\n' "$*" | grep -Fq -- "/trash/"; then
      exit 1
    fi
    command "$@"
    ;;
  cp)
    [ "${TEST_MODE:-}" != "repair_fail" ] || exit 1
    command "$@"
    ;;
  rm)
    if [ "${TEST_MODE:-}" = "empty_fail" ] && printf '%s\n' "$*" | grep -Fq -- "$TEST_TRASH_ITEM"; then
      exit 1
    fi
    if [ "${TEST_MODE:-}" = "direct_delete_fail" ] && printf '%s\n' "$*" | grep -Fq -- "$TEST_SCRIPT"; then
      exit 1
    fi
    command "$@"
    ;;
  *)
    command "$@"
    ;;
esac
EOF
  chmod +x "$case_dir/mock-sudo"

  export TEST_MODE="$mode"
  export PAM_APP_ROOT_OVERRIDE="$app"
  export PORTMASTER_LOONG_VERSION_FILE="$case_dir/loong-version"
  : > "$PORTMASTER_LOONG_VERSION_FILE"
  export PAM_STATE_DIR_OVERRIDE="$app/conf"
  export PAM_PORTMASTER_DIR_OVERRIDE="$scripts/PortMaster"
  export PAM_SCRIPTS_DIR_OVERRIDE="$scripts"
  export PAM_DIRECTORY_OVERRIDE="$gamedirs"
  export PAM_PORTKIT_BIN_OVERRIDE="$HOST_PORTKIT"
  export PAM_APPMANAGER_CLI_BIN_OVERRIDE="$HOST_APPMANAGER"
  export PAM_NATIVE_LAUNCHER_OVERRIDE="$scripts/APP Manager.sh"
  export DEVICE_ARCH=aarch64
  export ESUDO="$case_dir/mock-sudo"
  export TEST_COUNT="$case_dir/ui-count"
  export TEST_CONTROL_COUNT="$case_dir/control-count"
  export TEST_PLAN="$app/conf/plan.txt"
  export TEST_SIZE_FILE="$app/conf/sizes.tsv"
  export TEST_SCRIPT="$scripts/Game.sh"
  export TEST_IMAGE="$scripts/images/Game.png"
  case "$mode" in sibling_delete|sibling_restore) export TEST_IMAGE="$scripts/Game.png" ;; esac
  export TEST_GAME="$gamedirs/GameData"
  export TEST_OUTSIDE="$case_dir/outside.txt"
  export TEST_TRASH_ITEM="$app/trash/visible"
  export TEST_SELECTED_ITEM="$app/trash/selected/scripts/Game.sh"
  export TEST_SELECTED_IMAGE="$app/trash/selected/images/Game.png"
  export TEST_APPLY_HELPER="$app/conf/apply-helper.sh"
  export TEST_RUNNING_SOURCE="$scripts/.port.sh"
  export TEST_SELF="$scripts/APP Manager.sh"
  export TEST_BATCH_ROOT="$app/trash/protected-batch"
  export TEST_BUCKET_ROOT="$app/trash/protected-batch/scripts"
  : > "$TEST_OUTSIDE"

  case "$mode" in
    delete|same_root_delete|sibling_delete|direct_delete|direct_delete_fail)
      : > "$scripts/PORTS_cache-main.db"
      : > "$scripts/unrelated-cache.db"
      : > "$TEST_IMAGE"
      ;;
    empty|empty_fail)
      : > "$app/trash/visible"
      : > "$app/trash/.hidden"
      mkdir -p "$app/trash/.hidden-dir"
      : > "$app/trash/.hidden-dir/file"
      ;;
    appledouble)
      mkdir -p "$gamedirs/GameData/nested" "$scripts/images/deep"
      printf 'metadata\n' > "$gamedirs/GameData/._save.dat"
      printf 'metadata\n' > "$gamedirs/GameData/nested/._config"
      printf 'metadata\n' > "$scripts/._Game.sh"
      printf 'metadata\n' > "$scripts/images/deep/._Game.png"
      printf 'keep\n' > "$gamedirs/GameData/.keep"
      printf 'outside\n' > "$case_dir/._outside"
      ln -s "$gamedirs/GameData/.keep" "$gamedirs/GameData/._link"
      printf 'stale-size\n' > "$TEST_SIZE_FILE"
      ;;
    restore|restore_fail|restore_selected|delete_selected)
      rm -f "$TEST_SCRIPT" "$TEST_IMAGE"
      rm -rf "$TEST_GAME"
      batch="$app/trash/20260715-120000"
      case "$mode" in restore_selected|delete_selected) batch="$app/trash/selected" ;; esac
      mkdir -p "$batch/scripts" "$batch/images" "$batch/data/GameData"
      : > "$batch/scripts/Game.sh"
      : > "$batch/images/Game.png"
      : > "$batch/data/GameData/save.dat"
      ;;
    sibling_restore)
      rm -f "$TEST_SCRIPT" "$TEST_IMAGE"
      rm -rf "$TEST_GAME"
      batch="$app/trash/20260715-120000"
      mkdir -p "$batch/scripts" "$batch/script-images" "$batch/data/GameData"
      : > "$batch/scripts/Game.sh"
      : > "$batch/script-images/Game.png"
      : > "$batch/data/GameData/save.dat"
      ;;
    restore_legacy)
      rm -f "$TEST_SCRIPT" "$TEST_IMAGE"
      rm -rf "$TEST_GAME"
      mkdir -p "$app/trash/old-batch/GameData"
      : > "$app/trash/old-batch/Game.sh"
      : > "$app/trash/old-batch/Game.png"
      : > "$app/trash/old-batch/GameData/save.dat"
      ;;
    restore_conflict)
      printf 'installed version\n' > "$TEST_SCRIPT"
      mkdir -p "$app/trash/conflict/scripts"
      printf 'trash version\n' > "$app/trash/conflict/scripts/Game.sh"
      ;;
    restore_selected_invalid)
      export TEST_SELECTED_ITEM="$TEST_OUTSIDE"
      ;;
    restore_misbucket)
      rm -rf "$TEST_GAME"
      export TEST_SELECTED_ITEM="$app/trash/selected/scripts/GameData"
      mkdir -p "$TEST_SELECTED_ITEM"
      : > "$TEST_SELECTED_ITEM/save.dat"
      ;;
    delete_selected_invalid)
      export TEST_SELECTED_ITEM="$TEST_OUTSIDE"
      ;;
    delete_container_invalid)
      mkdir -p "$TEST_BUCKET_ROOT"
      : > "$TEST_BUCKET_ROOT/Keep.sh"
      ;;
  esac

  # Seed the same direct-item snapshot produced by --scan-sizes. Mutation
  # cases must update these rows incrementally instead of recursively running
  # du across every game directory again.
  case "$mode" in
    delete|same_root_delete|sibling_delete|direct_delete|direct_delete_fail|fail|empty|empty_fail|restore|sibling_restore|restore_legacy|restore_conflict|restore_fail|restore_selected|restore_misbucket|delete_selected)
      : > "$TEST_SIZE_FILE"
      seed_size() {
        [ -e "$1" ] || [ -L "$1" ] || return 0
        printf '4096\t%s\n' "$1" >> "$TEST_SIZE_FILE"
      }
      seed_size "$TEST_SCRIPT"; seed_size "$TEST_IMAGE"; seed_size "$TEST_GAME"
      for size_batch in "$app/trash"/* "$app/trash"/.[!.]* "$app/trash"/..?*; do
        [ -e "$size_batch" ] || [ -L "$size_batch" ] || continue
        if [ ! -d "$size_batch" ] || [ -L "$size_batch" ]; then seed_size "$size_batch"; continue; fi
        size_structured=0
        for size_bucket in scripts script-images data images; do
          [ -d "$size_batch/$size_bucket" ] || continue
          size_structured=1
          for size_item in "$size_batch/$size_bucket"/* "$size_batch/$size_bucket"/.[!.]* "$size_batch/$size_bucket"/..?*; do
            seed_size "$size_item"
          done
        done
        [ "$size_structured" = "1" ] && continue
        for size_item in "$size_batch"/* "$size_batch"/.[!.]* "$size_batch"/..?*; do seed_size "$size_item"; done
      done
      if [ "$mode" = "sibling_delete" ]; then
        awk -F '\t' -v path="$TEST_GAME" '$2 != path' "$TEST_SIZE_FILE" > "$TEST_SIZE_FILE.tmp"
        mv "$TEST_SIZE_FILE.tmp" "$TEST_SIZE_FILE"
      fi
      ;;
  esac

  if [ "$mode" = "renamed_launcher" ]; then
    # MiniLoong 把目标 SH 重命名为 .port.sh 后直接执行。helper 应复制
    # 真实运行的 $0，这样原文件名是否还存在都不影响。
    mv "$scripts/APP Manager.sh" "$scripts/.port.sh"
    PATH="$case_dir/bin:$PATH" bash "$scripts/.port.sh"
  elif [ "$mode" = "helper_fallback" ]; then
    # MiniLoong 会运行临时 .port.sh；它可能在 helper 复制前就被前端移除。
    # 必须从稳定文件回退生成 helper；Linux 真机还会先尝试 Bash 的 fd 255。
    cp "$scripts/APP Manager.sh" "$scripts/.port.sh"
    PATH="$case_dir/bin:$PATH" bash "$scripts/.port.sh"
  else
    PATH="$case_dir/bin:$PATH" bash "$scripts/APP Manager.sh"
  fi

  case "$mode" in
    delete|same_root_delete|sibling_delete)
      [ ! -e "$TEST_SCRIPT" ]
      [ ! -e "$TEST_IMAGE" ]
      [ ! -e "$TEST_GAME" ]
      [ -n "$(find "$app/trash" -path '*/scripts/Game.sh' -print -quit)" ]
      if [ "$mode" = "sibling_delete" ]; then
        [ -n "$(find "$app/trash" -path '*/script-images/Game.png' -print -quit)" ]
      else
        [ -n "$(find "$app/trash" -path '*/images/Game.png' -print -quit)" ]
      fi
      [ -n "$(find "$app/trash" -path '*/data/GameData' -print -quit)" ]
      # The operation does not signal completion until the derived size
      # snapshot reflects the new Trash paths.
      [ -f "$TEST_SIZE_FILE" ]
      grep -Fq "$app/trash/" "$TEST_SIZE_FILE"
      grep -Fq $'4096\t' "$TEST_SIZE_FILE"
      trash_game=$(find "$app/trash" -path '*/data/GameData' -print -quit)
      grep -Fq "$trash_game" "$TEST_SIZE_FILE"
      # APP Manager 不负责维护任何系统前端缓存；即使名字看起来熟悉也不能碰。
      [ -e "$scripts/PORTS_cache-main.db" ]
      [ -e "$scripts/unrelated-cache.db" ]
      [ ! -s "$app/conf/result.txt" ]
      if [ "$mode" = "same_root_delete" ]; then
        [ -n "$(find "$app/trash" -path '*/data/GameData' -print -quit)" ]
        [ -z "$(find "$app/trash" -path '*/scripts/GameData' -print -quit)" ]
      fi
      ;;
    direct_delete)
      [ ! -e "$TEST_SCRIPT" ]
      [ ! -e "$TEST_IMAGE" ]
      [ ! -e "$TEST_GAME" ]
      [ -z "$(find "$app/trash" -mindepth 1 -print -quit)" ]
      [ -e "$scripts/PORTS_cache-main.db" ]
      [ -e "$scripts/unrelated-cache.db" ]
      [ ! -s "$app/conf/result.txt" ]
      [ -f "$TEST_SIZE_FILE" ]
      ! grep -Fq "$TEST_SCRIPT" "$TEST_SIZE_FILE"
      ! grep -Fq "$TEST_IMAGE" "$TEST_SIZE_FILE"
      ! grep -Fq "$TEST_GAME" "$TEST_SIZE_FILE"
      ;;
    direct_delete_fail)
      [ -e "$TEST_SCRIPT" ]
      [ ! -e "$TEST_IMAGE" ]
      [ -e "$TEST_GAME" ]
      grep -Fxq $'FAIL\tdelete\tGame.sh' "$app/conf/result.txt"
      ;;
    direct_delete_invalid)
      [ -e "$TEST_OUTSIDE" ]
      grep -Fxq $'FAIL\toperation' "$app/conf/result.txt"
      ;;
    direct_delete_self)
      [ -e "$TEST_SELF" ]
      grep -Fxq $'FAIL\toperation' "$app/conf/result.txt"
      ;;
    fail)
      [ -e "$TEST_SCRIPT" ]
      [ -e "$TEST_GAME" ]
      grep -Fxq $'FAIL\ttrash\tGame.sh' "$app/conf/result.txt"
      ;;
    empty)
      [ -z "$(find "$app/trash" -mindepth 1 -print -quit)" ]
      [ ! -s "$app/conf/result.txt" ]
      ;;
    empty_fail)
      [ -e "$TEST_TRASH_ITEM" ]
      grep -Fxq $'FAIL\tempty_trash' "$app/conf/result.txt"
      ;;
    appledouble)
      [ ! -e "$gamedirs/GameData/._save.dat" ]
      [ ! -e "$gamedirs/GameData/nested/._config" ]
      [ ! -e "$scripts/._Game.sh" ]
      [ ! -e "$scripts/images/deep/._Game.png" ]
      [ -e "$gamedirs/GameData/.keep" ]
      [ -L "$gamedirs/GameData/._link" ]
      [ -e "$case_dir/._outside" ]
      [ -s "$TEST_SIZE_FILE" ]
      ! grep -Fq 'stale-size' "$TEST_SIZE_FILE"
      grep -Fxq $'OK\tappledouble\t4' "$app/conf/result.txt"
      ;;
    restore|sibling_restore|restore_legacy)
      [ -e "$TEST_SCRIPT" ]
      [ -e "$TEST_IMAGE" ]
      [ -e "$TEST_GAME/save.dat" ]
      [ -z "$(find "$app/trash" -mindepth 1 -print -quit)" ]
      [ ! -s "$app/conf/result.txt" ]
      [ -f "$TEST_SIZE_FILE" ]
      grep -Fq $'4096\t'"$TEST_GAME" "$TEST_SIZE_FILE"
      ;;
    restore_conflict)
      grep -Fxq 'installed version' "$TEST_SCRIPT"
      grep -Fxq 'trash version' "$app/trash/conflict/scripts/Game.sh"
      grep -Fxq $'FAIL\trestore\tGame.sh' "$app/conf/result.txt"
      ;;
    restore_fail)
      [ ! -e "$TEST_SCRIPT" ]
      [ -e "$app/trash/20260715-120000/scripts/Game.sh" ]
      grep -Fxq $'FAIL\trestore\tGame.sh' "$app/conf/result.txt"
      ;;
    restore_selected)
      [ -e "$TEST_SCRIPT" ]
      [ -e "$TEST_IMAGE" ]
      [ ! -e "$TEST_GAME" ]
      [ ! -e "$app/trash/selected/images/Game.png" ]
      [ -e "$app/trash/selected/data/GameData/save.dat" ]
      [ ! -s "$app/conf/result.txt" ]
      ;;
    restore_misbucket)
      [ -e "$TEST_GAME/save.dat" ]
      [ ! -e "$app/trash/selected/scripts/GameData" ]
      [ ! -s "$app/conf/result.txt" ]
      ;;
    delete_selected)
      [ ! -e "$app/trash/selected/scripts/Game.sh" ]
      [ ! -e "$app/trash/selected/images/Game.png" ]
      [ -e "$app/trash/selected/data/GameData/save.dat" ]
      [ ! -s "$app/conf/result.txt" ]
      ;;
    restore_selected_invalid)
      [ -e "$TEST_OUTSIDE" ]
      grep -Fxq $'FAIL\toperation' "$app/conf/result.txt"
      ;;
    delete_selected_invalid)
      [ -e "$TEST_OUTSIDE" ]
      grep -Fxq $'FAIL\toperation' "$app/conf/result.txt"
      ;;
    delete_container_invalid)
      [ -e "$TEST_BUCKET_ROOT/Keep.sh" ]
      [ "$(grep -Fxc $'FAIL\toperation' "$app/conf/result.txt")" = "2" ]
      ;;
    invalid)
      [ -e "$TEST_OUTSIDE" ]
      grep -Fxq $'FAIL\toperation' "$app/conf/result.txt"
      ;;
    no_plan)
      grep -Fxq $'FAIL\toperation' "$app/conf/result.txt"
      ;;
    renamed_launcher|helper_fallback)
      grep -Fq 'apply_plan()' "$TEST_APPLY_HELPER"
      grep -Fq '"apply_script": "'"$TEST_APPLY_HELPER"'"' "$app/conf/env.json"
      grep -Fq '"display_width": "960"' "$app/conf/env.json"
      grep -Fq '"display_height": "720"' "$app/conf/env.json"
      grep -Fq '"device_arch": "aarch64"' "$app/conf/env.json"
      grep -Fq '"device": ""' "$app/conf/env.json"
      grep -Fq '"param_device": "generic"' "$app/conf/env.json"
      grep -Fq '"analog_sticks": "2"' "$app/conf/env.json"
      grep -Fq '"lowres": "N"' "$app/conf/env.json"
      grep -Fq '"cur_tty": "/dev/tty0"' "$app/conf/env.json"
      grep -Fq '"sdl_controller_file": "'"$app"'/share/gamecontrollerdb.txt"' "$app/conf/env.json"
      grep -Fq '"path": "' "$app/conf/env.json"
      ;;
  esac
  [ ! -e "$TEST_PLAN" ]
  [ -x "$TEST_APPLY_HELPER" ]

  if [ "$mode" = "delete" ] || [ "$mode" = "same_root_delete" ]; then
    # 大目录统计由 helper 的独立后台模式产出缓存，不重跑 UI，
    # 也不再触发 get_controls 的平台启动画面。
    mkdir -p "$gamedirs/SizeProbe"
    printf 'size probe\n' > "$gamedirs/SizeProbe/probe.bin"
    if [ "$mode" = "same_root_delete" ]; then
      printf 'image probe\n' > "$gamedirs/SizeProbe.png"
    fi
    PAM_SOURCE_DIR="$scripts" bash "$TEST_APPLY_HELPER" --scan-sizes
    [ -s "$TEST_SIZE_FILE" ]
    grep -Fq "$gamedirs/SizeProbe" "$TEST_SIZE_FILE"
    if [ "$mode" = "same_root_delete" ]; then
      [ "$(grep -Fxc "$gamedirs/SizeProbe.png" < <(cut -f2- "$TEST_SIZE_FILE"))" = "1" ]
    fi
  fi
  [ "$(cat "$TEST_COUNT")" = "1" ]
  # APP-owned bootstrap never executes PortMaster control/get_controls.
  [ ! -e "$TEST_CONTROL_COUNT" ]
}

for mode in delete same_root_delete sibling_delete direct_delete direct_delete_fail direct_delete_invalid direct_delete_self fail empty empty_fail appledouble \
  restore sibling_restore restore_legacy restore_conflict restore_fail restore_selected \
  restore_selected_invalid restore_misbucket delete_selected delete_selected_invalid \
  delete_container_invalid invalid no_plan \
  renamed_launcher helper_fallback; do
  make_case "$mode"
done

echo "appmanager apply flow tests: PASS"
