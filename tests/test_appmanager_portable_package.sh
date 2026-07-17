#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/ports/appmanager/dist"
APP="$DIST/PortAppManager"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$ROOT/_kit/dist_port.sh" appmanager >/dev/null

[ -x "$DIST/APP Manager.sh" ]
[ -d "$APP" ]

for file in \
  love_ui/main.lua \
  love_ui/kit.lua \
  runtime/love.aarch64 \
  runtime/libs.aarch64/liblove-11.5.so \
  bin/gptokeyb \
  bin/curl \
  bin/curl-portable \
  bin/unzip-portable \
  bin/sha256sum-portable \
  bin/busybox \
  bin/busybox-portable \
  share/NotoSansSC-Regular.ttf \
  share/gamecontrollerdb.txt \
  share/cacert.pem \
  licenses/LICENSE-love.txt \
  licenses/LICENSE-gptokeyb.txt \
  licenses/LICENSE-noto.txt; do
  [ -s "$APP/$file" ] || {
    echo "portable app: missing $file" >&2
    exit 1
  }
done

[ -x "$APP/bin/curl-portable" ]
[ -x "$APP/bin/busybox-portable" ]
[ -x "$APP/bin/unzip-portable" ]
[ -x "$APP/bin/sha256sum-portable" ]
grep -Fq 'runtime/musl' "$APP/bin/curl-portable"
grep -Fq 'runtime/musl' "$APP/bin/busybox-portable"

file "$APP/runtime/love.aarch64" | grep -Fq 'ARM aarch64'
file "$APP/bin/gptokeyb" | grep -Fq 'ARM aarch64'
file "$APP/bin/curl" | grep -Fq 'ARM aarch64'
file "$APP/bin/busybox" | grep -Fq 'ARM aarch64'
[ "$(wc -c < "$APP/share/NotoSansSC-Regular.ttf")" -gt 1000000 ]

grep -Fq 'PAM_APP_ROOT="$PAM_DIR/PortAppManager"' "$DIST/APP Manager.sh"
grep -Fq 'PAM_ENV="$PAM_APP_ROOT/state/env.json"' "$DIST/APP Manager.sh"
grep -Fq 'PAM_APP_ROOT/runtime/love.aarch64' "$DIST/APP Manager.sh"
! grep -Fq 'runtimes/love_11.5/love.txt' "$DIST/APP Manager.sh"
! grep -Eq '(^|[[:space:]])(source|\.)[[:space:]]+.*(control|mod_).*\.txt' "$DIST/APP Manager.sh"
! grep -Fq 'LEGACY_GAMEDIR' "$DIST/APP Manager.sh"
! grep -Fq '/oem/loong/recover/userdata/app/portmaster' "$DIST/APP Manager.sh"
! grep -Fq 'command -v curl' "$DIST/APP Manager.sh"
! grep -Fq 'command -v wget' "$DIST/APP Manager.sh"
! grep -Fq 'RUNTIME_WGET' "$DIST/APP Manager.sh"
! grep -Fq 'RUNTIME_DOWNLOADER' "$DIST/APP Manager.sh"
grep -Fq 'candidate="$PAM_BIN_DIR/curl-portable"' "$DIST/APP Manager.sh"
[ "$(grep -Ec '^[ab] = enter$' "$APP/love_ui/ui.gptk")" = "2" ]
grep -Fq 'if env.portmaster_health=="healthy" then' "$APP/love_ui/main.lua"
grep -Fq 'L("Environment Management","环境管理")' "$APP/love_ui/main.lua"
grep -Fq 'L("Environment repair","环境修复")' "$APP/love_ui/main.lua"
grep -Fq ' --check-pm-update >/dev/null 2>&1 &' "$APP/love_ui/main.lua"

python3 - "$DIST/port.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["items"] == ["APP Manager.sh", "PortAppManager"]
assert data["attr"]["runtime"] == []
assert data["attr"]["arch"] == ["aarch64"]
PY

for unexpected in "$APP"/*.pck "$APP"/hacksdl "$APP"/libs/*.squashfs "$APP"/state; do
  [ ! -e "$unexpected" ] || { echo "portable app: unexpected distributable content: $unexpected" >&2; exit 1; }
done

# Launcher-relative discovery must survive frontend paths containing spaces and
# must be able to report a missing managed environment before starting LÖVE.
SPACED="$TMP/Ports With Space"
mkdir -p "$SPACED"
cp "$DIST/APP Manager.sh" "$SPACED/APP Manager.sh"
cp -R "$APP" "$SPACED/PortAppManager"
health="$(PAM_SOURCE_DIR="$SPACED" PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  bash "$SPACED/APP Manager.sh" --health-check)"
case "$health" in
  missing$'\t'*"$TMP/missing PortMaster") ;;
  *) echo "portable app: unexpected health result: $health" >&2; exit 1 ;;
esac

cat > "$SPACED/PortAppManager/bin/curl-portable" <<'CURL'
#!/bin/sh
[ "${1:-}" != "--version" ] || { echo 'curl test'; exit 0; }
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then out=$2; shift 2; else shift; fi
done
printf '%s\n' called >> "$PAM_TEST_CURL_LOG"
if [ -n "$out" ]; then
  printf '%s\n' '{' '  "stable": {' '    "version": "2026.07"' '  }' '}' > "$out"
else
  printf '%s\n' '{' '  "stable": {' '    "version": "2026.07"' '  }' '}'
fi
CURL
chmod +x "$SPACED/PortAppManager/bin/curl-portable"
PAM_TEST_CURL_LOG="$TMP/update-curl.log" PAM_SOURCE_DIR="$SPACED" \
  PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  bash "$SPACED/APP Manager.sh" --check-pm-update
grep -Fq $'\tok\t2026.07' "$SPACED/PortAppManager/state/portmaster-update.tsv"
first_count=$(wc -l < "$TMP/update-curl.log" | tr -d ' ')
PAM_TEST_CURL_LOG="$TMP/update-curl.log" PAM_SOURCE_DIR="$SPACED" \
  PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  bash "$SPACED/APP Manager.sh" --check-pm-update
[ "$(wc -l < "$TMP/update-curl.log" | tr -d ' ')" = "$first_count" ]
PAM_TEST_CURL_LOG="$TMP/update-curl.log" PAM_SOURCE_DIR="$SPACED" \
  PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  bash "$SPACED/APP Manager.sh" --check-pm-update-force
[ "$(wc -l < "$TMP/update-curl.log" | tr -d ' ')" -gt "$first_count" ]
python3 - "$SPACED/PortAppManager/state/env.json" <<'PY'
import json, sys
env=json.load(open(sys.argv[1], encoding="utf-8"))
assert env["update_status"] == "ok"
assert env["portmaster_latest"] == "2026.07"
PY

# Replace only the foreign-architecture executables with test doubles and run
# the real packaged launcher with no PortMaster tree or inherited PM variables.
# This proves bootstrap ordering and private-path selection on the host runner.
MARKER="$TMP/private-love-ran"
cat > "$SPACED/PortAppManager/runtime/love.aarch64" <<'LOVE'
#!/bin/sh
printf '%s\n' "$PAM_ENV" > "$PAM_TEST_MARKER"
LOVE
cp /usr/bin/true "$SPACED/PortAppManager/bin/gptokeyb"
chmod +x "$SPACED/PortAppManager/runtime/love.aarch64" "$SPACED/PortAppManager/bin/gptokeyb"
env -i PATH=/usr/bin:/bin HOME="$TMP/home" PAM_SOURCE_DIR="$SPACED" \
  PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" PAM_TEST_MARKER="$MARKER" \
  PAM_DEVICE_NAME_OVERRIDE='Test "device"\path' \
  bash "$SPACED/APP Manager.sh"
[ -s "$MARKER" ]
PAM_ENV_PATH="$(cat "$MARKER")"
[ "$PAM_ENV_PATH" = "$SPACED/PortAppManager/state/env.json" ]
python3 - "$PAM_ENV_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    env = json.load(handle)
assert env["portmaster_health"] == "missing"
assert env["app_root"].endswith("/PortAppManager")
assert env["gptokeyb"].endswith("/PortAppManager/bin/gptokeyb")
assert env["sdl_controller_file"].endswith("/PortAppManager/share/gamecontrollerdb.txt")
assert env["device_name"] == 'Test "device"\\path'
PY

echo "appmanager portable package tests: PASS"
