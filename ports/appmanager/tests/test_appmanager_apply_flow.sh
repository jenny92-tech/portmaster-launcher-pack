#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO_ROOT=$(cd "$ROOT/../.." && pwd)
bash "$REPO_ROOT/_kit/dist_port.sh" appmanager >/dev/null
cargo build --quiet --manifest-path "$REPO_ROOT/Cargo.toml" -p appmanager-cli
HOST_APPMANAGER="$REPO_ROOT/target/debug/appmanager-cli"
LAUNCHER="$ROOT/dist/APP Manager.sh"
APP_UI_DIR="$ROOT/love"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# UI work remains asynchronous, while mutations and recursive size scans are
# linked into the Rust main process rather than duplicated in Lua or Shell.
grep -Fq 'model.native.start,"apply"' "$APP_UI_DIR/app_operations.lua"
grep -Fq 'model.native.start,"scan-sizes"' "$APP_UI_DIR/main.lua"
grep -Fq 'apply_file_plan' "$REPO_ROOT/crates/appmanager-service/src/launcher.rs"
grep -Fq 'scan_size_cache' "$REPO_ROOT/crates/appmanager-service/src/launcher.rs"
grep -Fq '|candidate| stable_archive_valid(candidate, &expected_md5)' \
  "$REPO_ROOT/crates/appmanager-service/src/launcher.rs"
! grep -Fq '|_| valid()' "$REPO_ROOT/crates/appmanager-service/src/launcher.rs"
grep -Fq 'runtime/love.aarch64' "$LAUNCHER"
! grep -Fq 'launcher-session' "$LAUNCHER"
! grep -Eq '^(restore_one|restore_bucket|restore_selected_item|delete_selected_item|size_cache_apply_mutations)\(\)' "$LAUNCHER"
! sed -n '/^apply_plan()/,/^pending_value()/p' "$LAUNCHER" | grep -Fq 'rm -rf'
grep -Fq 'trash_action("DELETE_ITEM"' "$APP_UI_DIR/app_pages.lua"
grep -Fq 'item.kind="DELETE_MANAGED"' "$APP_UI_DIR/app_pages.lua"
grep -Fq 'Clean ._Files' "$APP_UI_DIR/app_pages.lua"
grep -Fq 'model.native.start,"inventory-refresh"' "$APP_UI_DIR/app_operations.lua"
grep -Fq 'L("Rescan","重新扫描")' "$APP_UI_DIR/app_pages.lua"

case_dir="$TMP/native-file-flow"
card="$case_dir/card"
scripts="$card/ports"
gamedirs="$card"
app="$gamedirs/jenny92-appmanager"
mkdir -p "$scripts/PortMaster/libs" "$app/state" "$app/trash" "$app/love_ui" \
  "$app/runtime/libs.aarch64" "$app/bin" "$app/share"
cp -R "$REPO_ROOT/config" "$app/config"
cp "$LAUNCHER" "$scripts/APP Manager.sh"
: > "$app/love_ui/main.lua"
: > "$app/love_ui/ui.gptk"
: > "$app/share/gamecontrollerdb.txt"
: > "$app/share/cacert.pem"
: > "$app/share/NotoSansSC-Regular.ttf"
cp /usr/bin/true "$app/bin/gptokeyb"

cat > "$scripts/PortMaster/control.txt" <<EOF
directory="${card#/}"
CFW_NAME="test"
DISPLAY_WIDTH=960
DISPLAY_HEIGHT=720
DEVICE_ARCH=aarch64
ANALOGSTICKS=2
LOWRES=N
CUR_TTY=/dev/tty0
SDL_GAMECONTROLLERCONFIG_FILE=/tmp/test-gamecontrollerdb.txt
ESUDO=""
GPTOKEYB=/bin/true
get_controls() { :; }
pm_platform_helper() { :; }
pm_finish() { :; }
EOF
: > "$scripts/PortMaster/device_info.txt"
: > "$scripts/PortMaster/funcs.txt"
: > "$scripts/PortMaster/pugwash"
: > "$scripts/PortMaster/PortMaster.sh"
chmod +x "$scripts/PortMaster/PortMaster.sh"
mkdir -p "$scripts/PortMaster/pylibs"
: > "$scripts/PortMaster/pylibs/module.py"

mkdir -p "$gamedirs/Shared"
printf 'GAMEDIR="/%s/Shared"\n' "${card#/}" > "$scripts/Keep.sh"
printf 'GAMEDIR="/%s/Shared"\n' "${card#/}" > "$scripts/Duplicate.sh"

export PAM_APP_ROOT_OVERRIDE="$app"
export PAM_STATE_DIR_OVERRIDE="$app/state"
export PAM_PORTMASTER_DIR_OVERRIDE="$scripts/PortMaster"
export PAM_SCRIPTS_DIR_OVERRIDE="$scripts"
export PAM_DIRECTORY_OVERRIDE="$gamedirs"
export PAM_NATIVE_LAUNCHER_OVERRIDE="$scripts/APP Manager.sh"
export DEVICE_ARCH=aarch64
printf '# native file plan\nTRASH\t%s\n' "$scripts/Duplicate.sh" > "$app/state/plan.txt"
"$HOST_APPMANAGER" --config-dir "$app/config" launcher-session \
  --source-dir "$scripts" --launcher "$scripts/APP Manager.sh" --app-root "$app" -- --apply-plan

[ -e "$scripts/Keep.sh" ]
[ ! -e "$scripts/Duplicate.sh" ]
[ -d "$gamedirs/Shared" ]
[ -n "$(find "$app/trash" -path '*/scripts/Duplicate.sh' -print -quit)" ]
[ ! -e "$app/state/plan.txt" ]
[ ! -e "$app/state/operation-active.tsv" ]
[ -f "$app/state/operation-active.lock" ]
grep -Fq '"script": "Keep.sh"' "$app/state/inventory.json"
! grep -Fq '"kind":"orphan-dir"' "$app/state/inventory.json"

# A killed helper cannot leave the next APP launch blocked forever. Startup
# removes only a marker whose recorded helper PID is demonstrably stale.
rm -f "$app/state/operation-active.lock"
mkdir "$app/state/operation-active.lock"
printf 'version\t1\ntoken\tstale\npid\t999999\nmode\t--apply-plan\n' > "$app/state/operation-active.lock/owner.tsv"
printf 'version\t1\ntoken\tstale\npid\t999999\n' > "$app/state/operation-active.tsv"
"$HOST_APPMANAGER" --config-dir "$app/config" launcher-session \
  --source-dir "$scripts" --launcher "$scripts/APP Manager.sh" --app-root "$app" -- --write-env
[ ! -e "$app/state/operation-active.tsv" ]
[ ! -d "$app/state/operation-active.lock" ]

# The standalone size refresh reuses the same config-derived roots and writes
# each direct managed item once, even when roots overlap on a device profile.
"$HOST_APPMANAGER" --config-dir "$app/config" launcher-session \
  --source-dir "$scripts" --launcher "$scripts/APP Manager.sh" --app-root "$app" -- --scan-sizes
[ "$(cut -f2- "$app/state/sizes.tsv" | grep -Fxc "$gamedirs/Shared")" = 1 ]

echo "appmanager native apply flow tests: PASS"
