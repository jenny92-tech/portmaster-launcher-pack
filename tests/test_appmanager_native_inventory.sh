#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cargo build --quiet --manifest-path "$ROOT/Cargo.toml" -p portkit-cli
mkdir -p "$TMP/source" "$TMP/app/bin" "$TMP/state"
cp -R "$ROOT/config" "$TMP/app/config"

cat > "$TMP/app/bin/appmanager-cli" <<'CLI'
#!/bin/sh
printf '%s\n' "$@" > "$PAM_TEST_INVENTORY_ARGS"
[ "${PAM_TEST_INVENTORY_FAIL:-0}" != 1 ] || exit 75
cat <<'JSON'
{"ok":true,"command":"device-inventory","data":{"schema":1,"cache_generations":{"schema":1,"global":0,"domains":{}},"entries":[],"ports":[],"refcount":{},"data_dirs":[],"images":[],"orphan_dirs":[],"orphan_images":[],"dead_scripts":[],"trash":[],"runtimes":{"need":{},"facts":[]}}}
JSON
CLI
chmod +x "$TMP/app/bin/appmanager-cli"

env PAM_TOOL_MODE=system \
  PAM_PORTKIT_BIN_OVERRIDE="$ROOT/target/debug/portkit" \
  PAM_APPMANAGER_CLI_BIN_OVERRIDE="$TMP/app/bin/appmanager-cli" \
  PAM_NATIVE_LAUNCHER_OVERRIDE='/mnt/SDCARD/Roms/PORTS/APP Manager.sh' \
  PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/state" \
  PAM_TEST_INVENTORY_ARGS="$TMP/args.txt" CFW_NAME=TrimUI \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --refresh-inventory

python3 - "$TMP/state/inventory.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1], encoding="utf-8"))
assert value["ok"] is True
assert value["command"] == "device-inventory"
assert value["data"]["schema"] == 1
PY
grep -Fxq device-inventory "$TMP/args.txt"
grep -Fxq -- --ignore-dir "$TMP/args.txt"
grep -Fxq autoinstall "$TMP/args.txt"
grep -Fxq -- --self-port "$TMP/args.txt"
grep -Fxq jenny92-appmanager "$TMP/args.txt"
if grep -Fxq -- --remote-config "$TMP/args.txt"; then
  echo "inventory unexpectedly used a missing remote config" >&2
  exit 1
fi

if env PAM_TOOL_MODE=system \
  PAM_PORTKIT_BIN_OVERRIDE="$ROOT/target/debug/portkit" \
  PAM_APPMANAGER_CLI_BIN_OVERRIDE="$TMP/app/bin/appmanager-cli" \
  PAM_NATIVE_LAUNCHER_OVERRIDE='/mnt/SDCARD/Roms/PORTS/APP Manager.sh' \
  PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/state" \
  PAM_TEST_INVENTORY_ARGS="$TMP/args.txt" PAM_TEST_INVENTORY_FAIL=1 CFW_NAME=TrimUI \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --refresh-inventory; then
  echo "failed inventory refresh unexpectedly succeeded" >&2
  exit 1
fi
[ ! -e "$TMP/state/inventory.json" ] || {
  echo "failed inventory refresh retained a stale snapshot" >&2
  exit 1
}

echo "appmanager native inventory bridge tests: PASS"
