#!/usr/bin/env bash
set -euo pipefail
export PAM_TOOL_MODE=system

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO_ROOT=$(cd "$ROOT/../.." && pwd)
bash "$REPO_ROOT/_kit/dist_port.sh" appmanager >/dev/null
cargo build --quiet --manifest-path "$REPO_ROOT/Cargo.toml" -p appmanager-cli -p portkit-cli
HOST_PORTKIT="$REPO_ROOT/target/debug/portkit"
HOST_APPMANAGER="$REPO_ROOT/target/debug/appmanager-cli"
LAUNCHER="$ROOT/dist/APP Manager.sh"
APP_UI_DIR="$ROOT/love"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# UI work remains asynchronous, while mutations and recursive size scans are
# owned by the native helper rather than duplicated in the launcher shell.
grep -Fq ' --apply-plan >/dev/null 2>&1 &' "$APP_UI_DIR/app_operations.lua"
grep -Fq ' --scan-sizes >/dev/null 2>&1 &' "$APP_UI_DIR/main.lua"
grep -Fq 'apply-file-plan' "$LAUNCHER"
grep -Fq 'scan-device-sizes' "$LAUNCHER"
grep -Fq -- '--set "PAM_SOURCE_DIR=$PAM_DIR"' "$LAUNCHER"
! grep -Eq '^(restore_one|restore_bucket|restore_selected_item|delete_selected_item|size_cache_apply_mutations)\(\)' "$LAUNCHER"
! sed -n '/^apply_plan()/,/^pending_value()/p' "$LAUNCHER" | grep -Fq 'rm -rf'
grep -Fq 'trash_action("DELETE_ITEM"' "$APP_UI_DIR/app_pages.lua"
grep -Fq 'item.kind="DELETE_MANAGED"' "$APP_UI_DIR/app_pages.lua"
grep -Fq 'Clean ._Files garbage files' "$APP_UI_DIR/app_pages.lua"

case_dir="$TMP/native-file-flow"
card="$case_dir/card"
scripts="$card/ports"
gamedirs="$card"
app="$gamedirs/jenny92-appmanager"
mkdir -p "$scripts/PortMaster/libs" "$app/state" "$app/trash" "$app/love_ui" \
  "$app/runtime/libs.aarch64" "$app/bin" "$app/share"
cp -R "$REPO_ROOT/config" "$app/config"
cp "$LAUNCHER" "$scripts/APP Manager.sh"
cp "$ROOT/love/json.lua" "$app/love_ui/json.lua"
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

cat > "$app/runtime/love.aarch64" <<'LOVE'
#!/usr/bin/env bash
set -euo pipefail
[ "${PAM_SOURCE_DIR:-}" = "$TEST_EXPECTED_SOURCE_DIR" ] || {
  echo "worker source context was not preserved: ${PAM_SOURCE_DIR:-<unset>}" >&2
  exit 98
}
printf '# native file plan\nTRASH\t%s\n' "$TEST_DUPLICATE" > "$TEST_PLAN"
rm -f -- "$TEST_TEMP_LAUNCHER"
bash "$TEST_APPLY_HELPER" --apply-plan
LOVE
chmod +x "$app/runtime/love.aarch64"

export PAM_APP_ROOT_OVERRIDE="$app"
export PAM_STATE_DIR_OVERRIDE="$app/state"
export PAM_PORTMASTER_DIR_OVERRIDE="$scripts/PortMaster"
export PAM_SCRIPTS_DIR_OVERRIDE="$scripts"
export PAM_DIRECTORY_OVERRIDE="$gamedirs"
export PAM_PORTKIT_BIN_OVERRIDE="$HOST_PORTKIT"
export PAM_APPMANAGER_CLI_BIN_OVERRIDE="$HOST_APPMANAGER"
export PAM_NATIVE_LAUNCHER_OVERRIDE="$scripts/APP Manager.sh"
export DEVICE_ARCH=aarch64
export TEST_EXPECTED_SOURCE_DIR="$scripts"
export TEST_DUPLICATE="$scripts/Duplicate.sh"
export TEST_PLAN="$app/state/plan.txt"
export TEST_APPLY_HELPER="$app/state/apply-helper.sh"
export TEST_TEMP_LAUNCHER="$scripts/.port.sh"

# MiniLoong runs a temporary .port.sh. The persisted state helper must retain
# the stable scripts root when it later handles the background plan.
cp "$scripts/APP Manager.sh" "$scripts/.port.sh"
bash "$scripts/.port.sh"

[ -e "$scripts/Keep.sh" ]
[ ! -e "$scripts/Duplicate.sh" ]
[ -d "$gamedirs/Shared" ]
[ -n "$(find "$app/trash" -path '*/scripts/Duplicate.sh' -print -quit)" ]
[ -x "$TEST_APPLY_HELPER" ]
[ ! -e "$TEST_PLAN" ]
[ ! -e "$app/state/operation-active.tsv" ]
[ ! -d "$app/state/operation-active.lock" ]
[ ! -s "$app/state/result.txt" ]
grep -Fq '"script":"Keep.sh"' "$app/state/inventory.json"
! grep -Fq '"kind":"orphan-dir"' "$app/state/inventory.json"

# A killed helper cannot leave the next APP launch blocked forever. Startup
# removes only a marker whose recorded helper PID is demonstrably stale.
mkdir "$app/state/operation-active.lock"
printf 'version\t1\ntoken\tstale\npid\t999999\nmode\t--apply-plan\n' > "$app/state/operation-active.lock/owner.tsv"
printf 'version\t1\ntoken\tstale\npid\t999999\n' > "$app/state/operation-active.tsv"
PAM_SOURCE_DIR="$scripts" bash "$scripts/APP Manager.sh" --write-env
[ ! -e "$app/state/operation-active.tsv" ]
[ ! -d "$app/state/operation-active.lock" ]

# The standalone size refresh reuses the same config-derived roots and writes
# each direct managed item once, even when roots overlap on a device profile.
PAM_SOURCE_DIR="$scripts" bash "$scripts/APP Manager.sh" --scan-sizes
[ "$(cut -f2- "$app/state/sizes.tsv" | grep -Fxc "$gamedirs/Shared")" = 1 ]

echo "appmanager native apply flow tests: PASS"
