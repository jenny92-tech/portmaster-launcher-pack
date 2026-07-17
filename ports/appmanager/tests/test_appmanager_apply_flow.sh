#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO_ROOT=$(cd "$ROOT/../.." && pwd)
"$REPO_ROOT/_kit/dist_port.sh" appmanager >/dev/null
LAUNCHER="$ROOT/dist/APP Manager.sh"
APP_UI="$ROOT/love/main.lua"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# helper must remain asynchronous so the LÖVE render loop stays responsive.
grep -Fq ' --apply-plan >/dev/null 2>&1 &' "$APP_UI"
grep -Fq 'if not file_exists(env.plan_file)' "$APP_UI"
grep -Fq ' --scan-sizes >/dev/null 2>&1 &' "$APP_UI"
grep -Fq 'trash_action("DELETE_ITEM"' "$APP_UI"
grep -Fq 'item.kind="DELETE_MANAGED"' "$APP_UI"
grep -Fq 'env.progress_file' "$APP_UI"
grep -Fq 'local batch_size=5' "$LAUNCHER"
if grep -Eq 'githubfast\.com|gitclone\.com' "$LAUNCHER"; then
  echo "unusable Git clone-only/403 services must not be Runtime candidates" >&2
  exit 1
fi
if grep -Fq 'os.execute(shquote(env.apply_script).." --apply-plan")' "$APP_UI"; then
  echo "appmanager helper must not block the render thread" >&2
  exit 1
fi

make_case() {
  local mode=$1
  local case_dir="$TMP/$1"
  local scripts="$case_dir/scripts"
  local card="$case_dir/card"
  local gamedirs="$card/ports"
  [ "$mode" != "same_root_delete" ] || scripts="$gamedirs"
  local app="$gamedirs/appmanager"
  mkdir -p "$scripts/PortMaster/libs" "$scripts/PortMaster/runtimes/love_11.5" \
    "$scripts/images" "$gamedirs/GameData" "$app/conf" "$app/trash" "$app/love_ui" "$case_dir/bin"
  cp "$LAUNCHER" "$scripts/APP Manager.sh"
  : > "$app/love_ui/main.lua"
  : > "$app/love_ui/ui.gptk"
  cat > "$app/love_ui/runtime_catalog.tsv" <<'EOF'
# Small deterministic catalog for downloader tests.
godot_4.5	aarch64	godot_4.5.aarch64.squashfs	20	20
gmtoolkit	aarch64	gmtoolkit.aarch64.squashfs.part.001,gmtoolkit.aarch64.squashfs.part.002,gmtoolkit.aarch64.squashfs.part.003	60	20,20,20
EOF
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
  delete|same_root_delete)
    printf '# test plan\nTRASH\t%s\nTRASH\t%s\nTRASH\t%s\n' "$TEST_SCRIPT" "$TEST_IMAGE" "$TEST_GAME" > "$TEST_PLAN" ;;
  direct_delete|direct_delete_fail)
    printf '# test plan\nDELETE_MANAGED\t%s\nDELETE_MANAGED\t%s\nDELETE_MANAGED\t%s\n' "$TEST_SCRIPT" "$TEST_IMAGE" "$TEST_GAME" > "$TEST_PLAN" ;;
  direct_delete_invalid) printf '# test plan\nDELETE_MANAGED\t%s\n' "$TEST_OUTSIDE" > "$TEST_PLAN" ;;
  direct_delete_self) printf '# test plan\nDELETE_MANAGED\t%s\n' "$TEST_SELF" > "$TEST_PLAN" ;;
  fail)
    printf '# test plan\nTRASH\t%s\nTRASH\t%s\n' "$TEST_SCRIPT" "$TEST_GAME" > "$TEST_PLAN" ;;
  empty|empty_fail) printf '# test plan\nEMPTY_TRASH\t-\n' > "$TEST_PLAN" ;;
  restore|restore_legacy|restore_conflict|restore_fail) printf '# test plan\nRESTORE_TRASH\t-\n' > "$TEST_PLAN" ;;
  restore_selected)
    printf '# test plan\nRESTORE_ITEM\t%s\nRESTORE_ITEM\t%s\n' "$TEST_SELECTED_ITEM" "$TEST_SELECTED_IMAGE" > "$TEST_PLAN" ;;
  restore_misbucket) printf '# test plan\nRESTORE_ITEM\t%s\n' "$TEST_SELECTED_ITEM" > "$TEST_PLAN" ;;
  delete_selected)
    printf '# test plan\nDELETE_ITEM\t%s\nDELETE_ITEM\t%s\n' "$TEST_SELECTED_ITEM" "$TEST_SELECTED_IMAGE" > "$TEST_PLAN" ;;
  delete_selected_invalid) printf '# test plan\nDELETE_ITEM\t%s\n' "$TEST_SELECTED_ITEM" > "$TEST_PLAN" ;;
  delete_container_invalid)
    printf '# test plan\nDELETE_ITEM\t%s\nDELETE_ITEM\t%s\n' "$TEST_BATCH_ROOT" "$TEST_BUCKET_ROOT" > "$TEST_PLAN" ;;
  runtime_repair|runtime_progress|runtime_custom|runtime_full|runtime_jsdelivr|runtime_proxy_failover|runtime_private_curl|runtime_bad_private_curl|runtime_wget|runtime_cached|runtime_resume|runtime_resume_reset) printf '# test plan\nINSTALL_RUNTIME\tgodot_4.5\n' > "$TEST_PLAN" ;;
  runtime_split) printf '# test plan\nINSTALL_RUNTIME\tgmtoolkit\n' > "$TEST_PLAN" ;;
  runtime_direct) printf '# test plan\nINSTALL_RUNTIME\tgodot_4.5\n' > "$TEST_PLAN" ;;
  runtime_invalid) printf '# test plan\nINSTALL_RUNTIME\t../escape\n' > "$TEST_PLAN" ;;
  runtime_fail) printf '# test plan\nINSTALL_RUNTIME\tgodot_4.5\n' > "$TEST_PLAN" ;;
  restore_selected_invalid) printf '# test plan\nRESTORE_ITEM\t%s\n' "$TEST_SELECTED_ITEM" > "$TEST_PLAN" ;;
  invalid) printf '# test plan\nTRASH\t%s\n' "$TEST_OUTSIDE" > "$TEST_PLAN" ;;
  no_plan) ;;
esac
[ "$TEST_MODE" != "renamed_launcher" ] || exit 0
bash "$TEST_APPLY_HELPER" --apply-plan
exit 0
LOVE
  chmod +x "$scripts/PortMaster/runtimes/love_11.5/love.aarch64"

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

  cat > "$case_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != "--version" ] || { printf 'curl test build\n'; exit 0; }
out=""
url=""
resume=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -C) resume=1; shift 2 ;;
    --connect-timeout|--max-time|--range|--retry|--retry-delay) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf 'resume=%s out=%s url=%s\n' "$resume" "$out" "$url" >> "$TEST_CURL_LOG"
[ "${TEST_MODE:-}" != "runtime_fail" ] || exit 22
[ "${TEST_MODE:-}" != "runtime_cached" ] || exit 22
if [ "${TEST_MODE:-}" = "runtime_proxy_failover" ]; then
  if [ -z "$out" ] && printf '%s' "$url" | grep -Fq 'secondary.test'; then sleep 1; fi
  if [ -n "$out" ] && printf '%s' "$url" | grep -Fq 'primary.test'; then exit 22; fi
fi
if [ "${TEST_MODE:-}" = "runtime_direct" ] && printf '%s' "$url" | grep -Fq 'proxy.test'; then
  exit 22
fi
if [ -n "$out" ]; then
  payload='hsqs-runtime-payload'
  if [ "${TEST_MODE:-}" = "runtime_progress" ]; then
    printf '%s' "${payload:0:4}" > "$out"
    sleep 1
    printf '%s' "${payload:4:8}" >> "$out"
    for _ in {1..25}; do
      speed=$(awk -F '\t' '$2 == "downloading" { print $8 }' "$TEST_PROGRESS_FILE" 2>/dev/null | tail -n 1)
      case "$speed" in ""|0|*[!0-9]*) ;; *) : > "$TEST_PROGRESS_OBSERVED"; break ;; esac
      sleep 0.1
    done
    printf '%s' "${payload:12}" >> "$out"
  elif [ "$resume" = "1" ] && [ "${TEST_MODE:-}" = "runtime_resume_reset" ] && [ ! -e "$TEST_RESUME_REJECTED" ]; then
    : > "$TEST_RESUME_REJECTED"
    exit 33
  elif [ "$resume" = "1" ] && [ "${TEST_MODE:-}" = "runtime_resume" ]; then
    current=$(wc -c < "$out" | tr -d '[:space:]')
    printf '%s' "$payload" | tail -c "+$((current + 1))" >> "$out"
  else
    printf '%s' "$payload" > "$out"
  fi
else
  printf 'hsqs'
fi
EOF
  chmod +x "$case_dir/bin/curl"
  if [ "$mode" = "runtime_private_curl" ]; then
    mkdir -p "$app/conf/runtime-tools"
    cp "$case_dir/bin/curl" "$app/conf/runtime-tools/curl"
    rm -f "$case_dir/bin/curl"
  elif [ "$mode" = "runtime_bad_private_curl" ]; then
    mkdir -p "$app/conf/runtime-tools"
    printf '#!/usr/bin/env bash\nexit 126\n' > "$app/conf/runtime-tools/curl"
    chmod +x "$app/conf/runtime-tools/curl"
  fi

  cat > "$case_dir/bin/wget" <<'EOF'
#!/usr/bin/env bash
out=""
url=""
resume=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -O) out=$2; shift 2 ;;
    -c) resume=1; shift ;;
    -T|--header) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf 'wget resume=%s out=%s url=%s\n' "$resume" "$out" "$url" >> "$TEST_CURL_LOG"
if [ "$out" = "-" ] || [ -z "$out" ]; then
  printf 'hsqs'
else
  printf 'hsqs-runtime-payload' > "$out"
fi
EOF
  chmod +x "$case_dir/bin/wget"
  [ "$mode" != "runtime_wget" ] || rm -f "$case_dir/bin/curl"

  export TEST_MODE="$mode"
  export TEST_COUNT="$case_dir/ui-count"
  export TEST_CONTROL_COUNT="$case_dir/control-count"
  export TEST_PLAN="$app/conf/plan.txt"
  export TEST_SIZE_FILE="$app/conf/sizes.tsv"
  export TEST_SCRIPT="$scripts/Game.sh"
  export TEST_IMAGE="$scripts/images/Game.png"
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
  export TEST_CURL_LOG="$case_dir/curl.log"
  export TEST_RESUME_REJECTED="$case_dir/resume-rejected"
  export TEST_PROGRESS_FILE="$app/conf/progress.tsv"
  export TEST_PROGRESS_OBSERVED="$case_dir/progress-observed"
  export PAM_RUNTIME_PROXIES="https://proxy.test"
  export PAM_RUNTIME_CUSTOM_PROXIES=""
  if [ "$mode" = "runtime_custom" ]; then
    export PAM_RUNTIME_PROXIES=""
    export PAM_RUNTIME_CUSTOM_PROXIES='custom|custom.test|https://custom.test'
  elif [ "$mode" = "runtime_full" ]; then
    export PAM_RUNTIME_PROXIES=""
    export PAM_RUNTIME_CUSTOM_PROXIES='full|full.test|https://full.test'
  elif [ "$mode" = "runtime_jsdelivr" ]; then
    export PAM_RUNTIME_PROXIES=""
    export PAM_RUNTIME_CUSTOM_PROXIES='jsdelivr|JSDelivr CDN|https://fastly.jsdelivr.net/gh'
  elif [ "$mode" = "runtime_proxy_failover" ]; then
    export PAM_RUNTIME_PROXIES=""
    export PAM_RUNTIME_CUSTOM_PROXIES=$'custom|primary.test|https://primary.test\ncustom|secondary.test|https://secondary.test'
  fi
  if [ "$mode" = "runtime_wget" ]; then
    export PAM_RUNTIME_WGET="$case_dir/bin/wget"
  else
    unset PAM_RUNTIME_WGET
  fi
  : > "$TEST_OUTSIDE"

  case "$mode" in
    delete|same_root_delete|direct_delete|direct_delete_fail)
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
    runtime_repair|runtime_progress|runtime_custom|runtime_full|runtime_jsdelivr|runtime_proxy_failover|runtime_private_curl|runtime_bad_private_curl|runtime_wget|runtime_cached|runtime_resume|runtime_resume_reset|runtime_fail)
      printf 'old-runtime' > "$scripts/PortMaster/libs/godot_4.5.squashfs"
      ;;
  esac
  if [ "$mode" = "runtime_cached" ] || [ "$mode" = "runtime_resume" ] ||
     [ "$mode" = "runtime_resume_reset" ] || [ "$mode" = "runtime_fail" ]; then
    runtime_ref=$(sed -n 's/^RUNTIME_SOURCE_REF="\([^"]*\)"/\1/p' "$scripts/APP Manager.sh" | head -n 1)
    runtime_cache="$app/conf/runtime-cache/$runtime_ref/godot_4.5"
    mkdir -p "$runtime_cache"
    if [ "$mode" = "runtime_cached" ]; then
      printf 'hsqs-runtime-payload' > "$runtime_cache/godot_4.5.aarch64.squashfs.download"
    else
      printf 'hsqs-run' > "$runtime_cache/godot_4.5.aarch64.squashfs.download"
    fi
  fi

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
    delete|same_root_delete)
      [ ! -e "$TEST_SCRIPT" ]
      [ ! -e "$TEST_IMAGE" ]
      [ ! -e "$TEST_GAME" ]
      [ -n "$(find "$app/trash" -path '*/scripts/Game.sh' -print -quit)" ]
      [ -n "$(find "$app/trash" -path '*/images/Game.png' -print -quit)" ]
      [ -n "$(find "$app/trash" -path '*/data/GameData' -print -quit)" ]
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
    restore|restore_legacy)
      [ -e "$TEST_SCRIPT" ]
      [ -e "$TEST_IMAGE" ]
      [ -e "$TEST_GAME/save.dat" ]
      [ -z "$(find "$app/trash" -mindepth 1 -print -quit)" ]
      [ ! -s "$app/conf/result.txt" ]
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
    runtime_repair|runtime_progress|runtime_private_curl|runtime_bad_private_curl)
      if ! grep -Fq 'hsqs-runtime-payload' "$scripts/PortMaster/libs/godot_4.5.squashfs"; then
        cat "$app/log.txt" "$app/conf/result.txt" >&2
        exit 1
      fi
      grep -Fq $'OK\truntime\tgodot_4.5\tproxy.test' "$app/conf/result.txt"
      grep -Fq 'https://proxy.test/https://github.com/PortsMaster/PortMaster-New/raw/' "$TEST_CURL_LOG"
      grep -Fxq $'1\tcomplete\tgodot_4.5\t1\t1\t20\t20\t0\tRuntime repair complete' "$app/conf/progress.tsv"
      [ "$mode" != "runtime_progress" ] || [ -e "$TEST_PROGRESS_OBSERVED" ]
      ;;
    runtime_wget)
      grep -Fxq 'hsqs-runtime-payload' "$scripts/PortMaster/libs/godot_4.5.squashfs"
      grep -Fq 'wget resume=0 out=' "$TEST_CURL_LOG"
      grep -Fq $'OK\truntime\tgodot_4.5\tproxy.test' "$app/conf/result.txt"
      ;;
    runtime_custom)
      grep -Fq $'OK\truntime\tgodot_4.5\tcustom.test' "$app/conf/result.txt"
      grep -Fq 'https://custom.test/PortsMaster/PortMaster-New/raw/' "$TEST_CURL_LOG"
      ;;
    runtime_full)
      grep -Fq $'OK\truntime\tgodot_4.5\tfull.test' "$app/conf/result.txt"
      grep -Fq 'https://full.test/https://github.com/PortsMaster/PortMaster-New/raw/' "$TEST_CURL_LOG"
      ;;
    runtime_jsdelivr)
      grep -Fq $'OK\truntime\tgodot_4.5\tJSDelivr CDN' "$app/conf/result.txt"
      grep -Fq 'https://fastly.jsdelivr.net/gh/PortsMaster/PortMaster-New@' "$TEST_CURL_LOG"
      ;;
    runtime_proxy_failover)
      grep -Fq $'OK\truntime\tgodot_4.5\tsecondary.test' "$app/conf/result.txt"
      grep -Fq 'https://primary.test/PortsMaster/PortMaster-New/raw/' "$TEST_CURL_LOG"
      grep -Fq 'https://secondary.test/PortsMaster/PortMaster-New/raw/' "$TEST_CURL_LOG"
      ;;
    runtime_cached)
      grep -Fxq 'hsqs-runtime-payload' "$scripts/PortMaster/libs/godot_4.5.squashfs"
      grep -Fq $'OK\truntime\tgodot_4.5\tCache' "$app/conf/result.txt"
      [ ! -s "$TEST_CURL_LOG" ]
      [ ! -d "$runtime_cache" ]
      ;;
    runtime_resume)
      grep -Fxq 'hsqs-runtime-payload' "$scripts/PortMaster/libs/godot_4.5.squashfs"
      grep -Fq 'resume=1 out=' "$TEST_CURL_LOG"
      [ ! -d "$runtime_cache" ]
      ;;
    runtime_resume_reset)
      grep -Fxq 'hsqs-runtime-payload' "$scripts/PortMaster/libs/godot_4.5.squashfs"
      grep -Fq 'resume=1 out=' "$TEST_CURL_LOG"
      [ -e "$TEST_RESUME_REJECTED" ]
      [ ! -d "$runtime_cache" ]
      ;;
    runtime_split)
      [ "$(wc -c < "$scripts/PortMaster/libs/gmtoolkit.squashfs" | tr -d ' ')" = "60" ]
      grep -Fq $'OK\truntime\tgmtoolkit\tproxy.test' "$app/conf/result.txt"
      ;;
    runtime_direct)
      grep -Fq 'hsqs-runtime-payload' "$scripts/PortMaster/libs/godot_4.5.squashfs"
      grep -Fq $'OK\truntime\tgodot_4.5\tGitHub' "$app/conf/result.txt"
      grep -Fq 'raw.githubusercontent.com/PortsMaster/PortMaster-New/' "$TEST_CURL_LOG"
      ;;
    runtime_invalid)
      [ ! -e "$scripts/PortMaster/libs/escape.squashfs" ]
      grep -Fq $'FAIL\truntime\t../escape\tinvalid-name' "$app/conf/result.txt"
      ;;
    runtime_fail)
      grep -Fxq 'old-runtime' "$scripts/PortMaster/libs/godot_4.5.squashfs"
      grep -Fq $'FAIL\truntime\tgodot_4.5\tno-source' "$app/conf/result.txt"
      grep -Fxq 'hsqs-run' "$runtime_cache/godot_4.5.aarch64.squashfs.download"
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
      grep -Fq '"display_width": "854"' "$app/conf/env.json"
      grep -Fq '"display_height": "480"' "$app/conf/env.json"
      grep -Fq '"device_arch": "aarch64"' "$app/conf/env.json"
      grep -Fq '"device": "test-controller"' "$app/conf/env.json"
      grep -Fq '"param_device": "test-device"' "$app/conf/env.json"
      grep -Fq '"analog_sticks": "2"' "$app/conf/env.json"
      grep -Fq '"lowres": "N"' "$app/conf/env.json"
      grep -Fq '"cur_tty": "/dev/tty0"' "$app/conf/env.json"
      grep -Fq '"sdl_controller_file": "/tmp/test-gamecontrollerdb.txt"' "$app/conf/env.json"
      grep -Fq '"path": "' "$app/conf/env.json"
      ;;
  esac
  [ ! -e "$TEST_PLAN" ]
  [ -x "$TEST_APPLY_HELPER" ]

  if [ "$mode" = "delete" ]; then
    # 大目录统计由 helper 的独立后台模式产出缓存，不重跑 UI，
    # 也不再触发 get_controls 的平台启动画面。
    mkdir -p "$gamedirs/SizeProbe"
    printf 'size probe\n' > "$gamedirs/SizeProbe/probe.bin"
    PAM_SOURCE_DIR="$scripts" bash "$TEST_APPLY_HELPER" --scan-sizes
    [ -s "$TEST_SIZE_FILE" ]
    grep -Fq "$gamedirs/SizeProbe" "$TEST_SIZE_FILE"
  fi
  [ "$(cat "$TEST_COUNT")" = "1" ]
  # 启动 UI 时调用一次；后台 helper 不能再触发平台启动画面/手柄初始化。
  [ "$(cat "$TEST_CONTROL_COUNT")" = "1" ]
}

for mode in delete same_root_delete direct_delete direct_delete_fail direct_delete_invalid direct_delete_self fail empty empty_fail \
  restore restore_legacy restore_conflict restore_fail restore_selected \
  restore_selected_invalid restore_misbucket delete_selected delete_selected_invalid \
  delete_container_invalid invalid no_plan runtime_repair runtime_progress runtime_custom runtime_full runtime_jsdelivr runtime_proxy_failover runtime_private_curl runtime_bad_private_curl runtime_wget runtime_cached runtime_resume runtime_resume_reset \
  runtime_split runtime_direct runtime_invalid runtime_fail \
  renamed_launcher helper_fallback; do
  make_case "$mode"
done

echo "appmanager apply flow tests: PASS"
