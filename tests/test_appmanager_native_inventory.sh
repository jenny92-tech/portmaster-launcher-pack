#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cargo build --quiet --manifest-path "$ROOT/Cargo.toml" -p appmanager-cli
CLI="$ROOT/target/debug/appmanager-cli"
DEVICE="$TMP/device"
SCRIPTS="$DEVICE/mnt/sdcard/roms/ports"
APP="$TMP/app"
STATE="$TMP/state"
mkdir -p "$DEVICE/loong" "$SCRIPTS/PortMaster/libs" "$SCRIPTS/Game" "$APP/bin" "$STATE"
printf '1.0\n' > "$DEVICE/loong/loong_version"
printf '#!/bin/sh\n' > "$SCRIPTS/APP Manager.sh"
printf 'GAMEDIR="/%s/Game"\n' "${SCRIPTS#/}" > "$SCRIPTS/Game.sh"
cp -R "$ROOT/config" "$APP/config"

env PAM_SOURCE_DIR="$SCRIPTS" PAM_APP_ROOT_OVERRIDE="$APP" PAM_STATE_DIR_OVERRIDE="$STATE" \
  PAM_NATIVE_ROOT="$DEVICE" PAM_NATIVE_LAUNCHER_OVERRIDE="$SCRIPTS/APP Manager.sh" \
  PAM_PORTMASTER_DIR_OVERRIDE="$SCRIPTS/PortMaster" \
  "$CLI" --config-dir "$APP/config" launcher-session --source-dir "$SCRIPTS" \
  --launcher "$SCRIPTS/APP Manager.sh" --app-root "$APP" -- --refresh-inventory

python3 - "$STATE/inventory.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1], encoding="utf-8"))
assert value["schema"] == 2
assert any(item["script"] == "Game.sh" for item in value["ports"])
assert all(item.get("script") != "APP Manager.sh" for item in value["ports"])
PY

echo "appmanager native inventory bridge tests: PASS"
