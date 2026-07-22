#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/ports/appmanager/dist"
APP="$DIST/jenny92-appmanager"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash "$ROOT/_kit/dist_port.sh" appmanager >/dev/null
cargo build --quiet --manifest-path "$ROOT/Cargo.toml" -p appmanager-cli
HOST_APPMANAGER="$ROOT/target/debug/appmanager-cli"

[ -x "$DIST/APP Manager.sh" ]
[ -d "$APP" ]
[ ! -e "$APP/json_tool" ] || {
  echo "portable app: obsolete LÖVE JSON helper was packaged" >&2
  exit 1
}

for file in \
  config/config.json \
  config/platforms/miniloong.json \
  config/platforms/trimui.json \
  love_ui/main.lua \
  love_ui/kit.lua \
  love_ui/app_native.lua \
  runtime/love.aarch64 \
  bin/gptokeyb \
  share/NotoSansSC-Regular.ttf \
  share/gamecontrollerdb.txt \
  share/cacert.pem \
  licenses/LICENSE-love-lite-APACHE-2.0.txt \
  licenses/LICENSE-json.lua-MIT.txt \
  licenses/LICENSE-gptokeyb.txt \
  licenses/LICENSE-noto.txt; do
  [ -s "$APP/$file" ] || {
    echo "portable app: missing $file" >&2
    exit 1
  }
done

assert_exact_files() {
  local directory="$1" expected actual
  shift
  expected=$(printf '%s\n' "$@" | LC_ALL=C sort)
  actual=$(find "$directory" -type f -print | sed "s#^$directory/##" | LC_ALL=C sort)
  [ "$actual" = "$expected" ] || {
    echo "portable app: unexpected files under ${directory#$APP/}" >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    exit 1
  }
}

# These directories are deliberately closed sets. Every shipped executable,
# compatibility library and legal notice must have a current runtime owner.
assert_exact_files "$APP/bin" \
  gptokeyb
assert_exact_files "$APP/runtime" \
  love.aarch64
assert_exact_files "$APP/licenses" \
  LICENSE-FreeType-FTL.txt \
  LICENSE-certifi.txt \
  LICENSE-freetype-sys-MIT.txt \
  LICENSE-gptokeyb.txt \
  LICENSE-json.lua-MIT.txt \
  LICENSE-love-lite-APACHE-2.0.txt \
  LICENSE-noto.txt \
  THIRD-PARTY-SOURCES.md

cmp "$ROOT/ports/appmanager/love/json.lua" "$APP/love_ui/json.lua"
grep -Fq 'Copyright (c) 2020 rxi' "$APP/love_ui/json.lua"
grep -Fq 'local json = { _version = "0.1.2" }' "$APP/love_ui/json.lua"
grep -Fq 'dbf4b2dd2eb7c23be2773c89eb059dadd6436f94' "$APP/licenses/THIRD-PARTY-SOURCES.md"
grep -Fq 'be8930d3c9fd70ab210918218f7cbffd2df1a30a' "$APP/licenses/THIRD-PARTY-SOURCES.md"
grep -Fq 'statically links FreeType' "$APP/licenses/THIRD-PARTY-SOURCES.md"

[ ! -e "$APP/bin/.native-revision" ]
[ ! -e "$APP/native-revision.txt" ]
[ ! -e "$APP/love-lite-revision.txt" ]
for removed in curl curl-portable unzip-portable sha256sum-portable; do
  [ ! -e "$APP/bin/$removed" ] || { echo "portable app: obsolete helper $removed was packaged" >&2; exit 1; }
done
[ ! -e "$APP/runtime/musl" ]

file "$APP/runtime/love.aarch64" | grep -Fq 'ARM aarch64'
! grep -aFq 'liblove-11.5.so' "$APP/runtime/love.aarch64"
! grep -aFq 'libluajit-5.1.so.2' "$APP/runtime/love.aarch64"
grep -aFq "$(python3 "$ROOT/_kit/love_lite_revision.py" "$ROOT")" "$APP/runtime/love.aarch64"
file "$APP/bin/gptokeyb" | grep -Fq 'ARM aarch64'
[ "$(wc -c < "$APP/share/NotoSansSC-Regular.ttf")" -gt 1000000 ]

grep -Fq 'runtime/love.aarch64' "$DIST/APP Manager.sh"
! grep -Fq 'launcher-session' "$DIST/APP Manager.sh"
[ "$(wc -l < "$DIST/APP Manager.sh" | tr -d ' ')" -le 120 ]
grep -A2 -Fq 'indeterminate=true,stage=L("Checking device configuration"' "$APP/love_ui/main.lua"
! grep -Fq 'Event::ControllerButton' "$ROOT/crates/love-lite/src/main.rs"
! grep -Fq 'PAM_LOVE_LIBRARY_PATH' "$DIST/APP Manager.sh"
! grep -Fq 'resolved_love_library_path' "$DIST/APP Manager.sh"
! grep -Fq 'runtime/libs.aarch64' "$DIST/APP Manager.sh"
! grep -Fq 'compat.rocknix.aarch64' "$DIST/APP Manager.sh"
! grep -Fq 'runtimes/love_11.5/love.txt' "$DIST/APP Manager.sh"
! grep -Eq '(^|[[:space:]])(source|\.)[[:space:]]+.*(control|mod_).*\.txt' "$DIST/APP Manager.sh"
! grep -Fq 'LEGACY_GAMEDIR' "$DIST/APP Manager.sh"
! grep -Fq '/oem/loong/recover/userdata/app/portmaster' "$DIST/APP Manager.sh"
! grep -Fq 'command -v curl' "$DIST/APP Manager.sh"
! grep -Fq 'command -v wget' "$DIST/APP Manager.sh"
! grep -Fq 'RUNTIME_WGET' "$DIST/APP Manager.sh"
! grep -Fq 'RUNTIME_DOWNLOADER' "$DIST/APP Manager.sh"
! grep -Fq 'pam_tools_init' "$DIST/APP Manager.sh"
! grep -Fq 'github_proxy_' "$DIST/APP Manager.sh"
! grep -Fq 'fetch-stable-release' "$DIST/APP Manager.sh"
! grep -Fq 'zip-readable' "$DIST/APP Manager.sh"
[ "$(grep -Ec '^[ab] = enter$' "$APP/love_ui/ui.gptk")" = "2" ]
[ "$(grep -Ec '^(start|back) = f10$' "$APP/love_ui/ui.gptk")" = "2" ]
! grep -Eq '^(start|back) = (enter|esc)$' "$APP/love_ui/ui.gptk"
grep -Fq 'env.portmaster_health=="healthy" or env.portmaster_management=="system"' "$APP/love_ui/main.lua"
grep -Fq '"portmaster_management"' "$ROOT/crates/appmanager-cli/src/launcher.rs"
grep -Fq 'L("Environment Management","环境管理")' "$APP/love_ui/app_environment.lua"
grep -Fq 'L("PortMaster required","需要安装 PortMaster")' "$APP/love_ui/app_environment.lua"
grep -Fq 'model.native.start,"update-check-if-stale"' "$APP/love_ui/main.lua"
python3 - "$ROOT/ports/appmanager/trimui-app/icon.png" <<'PY'
import struct
import sys

with open(sys.argv[1], "rb") as handle:
    header = handle.read(26)
assert header[:8] == b"\x89PNG\r\n\x1a\n"
assert struct.unpack(">II", header[16:24]) == (300, 300)
assert header[25] == 6  # RGBA
PY

python3 - "$DIST/port.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["name"] == "jenny92-appmanager.zip"
assert data["items"] == ["APP Manager.sh", "jenny92-appmanager"]
assert data["attr"]["runtime"] == []
assert data["attr"]["arch"] == ["aarch64"]
PY

for unexpected in "$APP"/*.pck "$APP"/hacksdl "$APP"/libs/*.squashfs "$APP"/state; do
  [ ! -e "$unexpected" ] || { echo "portable app: unexpected distributable content: $unexpected" >&2; exit 1; }
done

# Launcher-relative discovery must survive frontend paths containing spaces and
# must be able to report a missing managed environment before starting LÖVE.
SPACED="$TMP/Ports With Space"
mkdir -p "$SPACED/images"
cp "$DIST/APP Manager.sh" "$SPACED/APP Manager.sh"
cp "$DIST/APP Manager.png" "$SPACED/APP Manager.png"
cp -R "$APP" "$SPACED/jenny92-appmanager"
health="$(PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  PAM_NATIVE_LAUNCHER_OVERRIDE="$SPACED/APP Manager.sh" \
  "$HOST_APPMANAGER" --config-dir "$SPACED/jenny92-appmanager/config" launcher-session \
  --source-dir "$SPACED" --launcher "$SPACED/APP Manager.sh" \
  --app-root "$SPACED/jenny92-appmanager" -- --health-check)"
case "$health" in
  missing$'\t'*"$TMP/missing PortMaster") ;;
  *) echo "portable app: unexpected health result: $health" >&2; exit 1 ;;
esac
printf '%s\tok\t2026.07\n' "$(date +%s)" > "$SPACED/jenny92-appmanager/state/portmaster-update.tsv"
PAM_SOURCE_DIR="$SPACED" PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  PAM_NATIVE_LAUNCHER_OVERRIDE="$SPACED/APP Manager.sh" \
  "$HOST_APPMANAGER" --config-dir "$SPACED/jenny92-appmanager/config" launcher-session \
  --source-dir "$SPACED" --launcher "$SPACED/APP Manager.sh" \
  --app-root "$SPACED/jenny92-appmanager" -- --write-env
grep -Fq $'\tok\t2026.07' "$SPACED/jenny92-appmanager/state/portmaster-update.tsv"
python3 - "$SPACED/jenny92-appmanager/state/env.json" <<'PY'
import json, sys
env=json.load(open(sys.argv[1], encoding="utf-8"))
assert env["update_status"] == "ok"
assert env["portmaster_latest"] == "2026.07"
PY

# Replace the foreign-architecture executable with a recorder. This tests only
# the Shell bootstrap boundary; Rust session behavior is covered above.
rm -f "$SPACED/jenny92-appmanager/runtime/love.aarch64"
cat > "$SPACED/jenny92-appmanager/runtime/love.aarch64" <<'LOVE'
#!/bin/sh
printf '%s\n%s\n%s\n%s\n' "$PAM_SOURCE_DIR" "$PAM_APP_ROOT" "$PAM_LAUNCHER" "$1" > "$PAM_APP_ROOT/launcher-context.txt"
LOVE
chmod +x "$SPACED/jenny92-appmanager/runtime/love.aarch64"
env -i PATH=/usr/bin:/bin HOME="$TMP/home" PAM_SOURCE_DIR="$SPACED" \
  PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  PAM_NATIVE_LAUNCHER_OVERRIDE="$SPACED/APP Manager.sh" \
  bash "$SPACED/APP Manager.sh"
sed -n '1p' "$SPACED/jenny92-appmanager/launcher-context.txt" | grep -Fxq "$SPACED"
sed -n '2p' "$SPACED/jenny92-appmanager/launcher-context.txt" | grep -Fxq "$SPACED/jenny92-appmanager"
sed -n '3p' "$SPACED/jenny92-appmanager/launcher-context.txt" | grep -Fxq "$SPACED/APP Manager.sh"
sed -n '4p' "$SPACED/jenny92-appmanager/launcher-context.txt" | grep -Fxq "$SPACED/jenny92-appmanager/love_ui"

echo "appmanager portable package tests: PASS"
