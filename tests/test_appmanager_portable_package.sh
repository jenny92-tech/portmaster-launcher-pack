#!/usr/bin/env bash
set -euo pipefail
export PAM_TOOL_MODE=system # Host fixtures run on macOS, not the packaged aarch64 runtime.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/ports/appmanager/dist"
APP="$DIST/jenny92-appmanager"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash "$ROOT/_kit/dist_port.sh" appmanager >/dev/null
cargo build --quiet --manifest-path "$ROOT/Cargo.toml" -p portkit-cli -p appmanager-cli
HOST_PORTKIT="$ROOT/target/debug/portkit"
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
  runtime/love.aarch64 \
  runtime/libs.aarch64/liblove-11.5.so \
  runtime/compat.rocknix.aarch64/libtheoradec.so.1 \
  bin/gptokeyb \
  bin/busybox \
  bin/busybox-portable \
  bin/portkit \
  bin/appmanager-cli \
  share/NotoSansSC-Regular.ttf \
  share/gamecontrollerdb.txt \
  share/cacert.pem \
  licenses/LICENSE-love.txt \
  licenses/LICENSE-libtheora-BSD-3-Clause.txt \
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
  appmanager-cli busybox busybox-portable gptokeyb portkit
assert_exact_files "$APP/runtime" \
  compat.rocknix.aarch64/libtheoradec.so.1 \
  libs.aarch64/liblove-11.5.so \
  libs.aarch64/libluajit-5.1.so.2 \
  libs.aarch64/libmodplug.so.1 \
  libs.aarch64/libogg.so.0 \
  love.aarch64 \
  musl/libc.musl-aarch64.so.1
assert_exact_files "$APP/licenses" \
  LICENSE-busybox-GPL-2.0.txt \
  LICENSE-certifi.txt \
  LICENSE-gptokeyb.txt \
  LICENSE-json.lua-MIT.txt \
  LICENSE-libmodplug.txt \
  LICENSE-libogg.txt \
  LICENSE-libtheora-BSD-3-Clause.txt \
  LICENSE-love.txt \
  LICENSE-luajit.txt \
  LICENSE-noto.txt \
  THIRD-PARTY-SOURCES.md

cmp "$ROOT/ports/appmanager/love/json.lua" "$APP/love_ui/json.lua"
grep -Fq 'Copyright (c) 2020 rxi' "$APP/love_ui/json.lua"
grep -Fq 'local json = { _version = "0.1.2" }' "$APP/love_ui/json.lua"
grep -Fq 'dbf4b2dd2eb7c23be2773c89eb059dadd6436f94' "$APP/licenses/THIRD-PARTY-SOURCES.md"
grep -Fq 'c4055ada0f38c34a785e8527d278218e6b77e9d48fff7c4e5b6437b0c5ecac56' "$APP/licenses/THIRD-PARTY-SOURCES.md"
[ "$(shasum -a 256 "$APP/runtime/compat.rocknix.aarch64/libtheoradec.so.1" | awk '{print $1}')" = \
  "c4055ada0f38c34a785e8527d278218e6b77e9d48fff7c4e5b6437b0c5ecac56" ]
file "$APP/runtime/compat.rocknix.aarch64/libtheoradec.so.1" | grep -Fq 'ARM aarch64'

[ -x "$APP/bin/busybox-portable" ]
grep -Fq 'runtime/musl' "$APP/bin/busybox-portable"
[ ! -e "$APP/bin/.native-revision" ]
[ ! -e "$APP/native-revision.txt" ]
for removed in curl curl-portable unzip-portable sha256sum-portable; do
  [ ! -e "$APP/bin/$removed" ] || { echo "portable app: obsolete helper $removed was packaged" >&2; exit 1; }
done
[ "$(find "$APP/runtime/musl" -maxdepth 1 -type f | wc -l | tr -d ' ')" = 1 ]
[ -f "$APP/runtime/musl/libc.musl-aarch64.so.1" ]

file "$APP/runtime/love.aarch64" | grep -Fq 'ARM aarch64'
file "$APP/bin/gptokeyb" | grep -Fq 'ARM aarch64'
file "$APP/bin/busybox" | grep -Fq 'ARM aarch64'
file "$APP/bin/portkit" | grep -Fq 'ARM aarch64'
file "$APP/bin/appmanager-cli" | grep -Fq 'ARM aarch64'
file "$APP/bin/portkit" | grep -Fq 'statically linked'
file "$APP/bin/appmanager-cli" | grep -Fq 'statically linked'
[ "$(wc -c < "$APP/share/NotoSansSC-Regular.ttf")" -gt 1000000 ]

grep -Fq 'PAM_APP_ROOT="$PAM_DIR/jenny92-appmanager"' "$DIST/APP Manager.sh"
grep -Fq 'PAM_ENV="$PAM_APP_ROOT/state/env.json"' "$DIST/APP Manager.sh"
grep -Fq 'PAM_APP_ROOT/runtime/love.aarch64' "$DIST/APP Manager.sh"
grep -Fq 'PAM_LOVE_LIBRARY_PATH="$PAM_THEORA_COMPAT_DIR:$PAM_LOVE_LIBRARY_PATH"' "$DIST/APP Manager.sh"
! grep -Fq 'runtimes/love_11.5/love.txt' "$DIST/APP Manager.sh"
! grep -Eq '(^|[[:space:]])(source|\.)[[:space:]]+.*(control|mod_).*\.txt' "$DIST/APP Manager.sh"
! grep -Fq 'LEGACY_GAMEDIR' "$DIST/APP Manager.sh"
! grep -Fq '/oem/loong/recover/userdata/app/portmaster' "$DIST/APP Manager.sh"
! grep -Fq 'command -v curl' "$DIST/APP Manager.sh"
! grep -Fq 'command -v wget' "$DIST/APP Manager.sh"
! grep -Fq 'RUNTIME_WGET' "$DIST/APP Manager.sh"
! grep -Fq 'RUNTIME_DOWNLOADER' "$DIST/APP Manager.sh"
grep -Fq 'pam_tools_init' "$DIST/APP Manager.sh"
grep -Fq 'tools=$PAM_TOOL_PROVIDER${PAM_TOOL_PROBE_FAILURE:+ system_probe=$PAM_TOOL_PROBE_FAILURE}' "$DIST/APP Manager.sh"
! grep -Fq 'github_proxy_' "$DIST/APP Manager.sh"
grep -Fq 'file digest --algorithm sha256' "$DIST/APP Manager.sh"
grep -Fq 'file zip-readable --input' "$DIST/APP Manager.sh"
# The three supported TrimUI firmware packages execute /bin/bash through
# BusyBox. Keep generated device code inside the syntax subset that exact
# interpreter accepts; desktop GNU Bash must not be the only parser tested.
if grep -nE '<<<|(^|[[:space:]])(local|declare)[[:space:]]+-[A-Za-z]*[aA]|read[[:space:]]+(-r[[:space:]]+)?-a|printf[[:space:]]+-v|^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\(' \
    "$DIST/APP Manager.sh"; then
  echo "portable app: generated launcher uses unsupported BusyBox Bash syntax" >&2
  exit 1
fi
[ "$(grep -Ec '^[ab] = enter$' "$APP/love_ui/ui.gptk")" = "2" ]
[ "$(grep -Ec '^(start|back) = f10$' "$APP/love_ui/ui.gptk")" = "2" ]
! grep -Eq '^(start|back) = (enter|esc)$' "$APP/love_ui/ui.gptk"
grep -Fq 'env.portmaster_health=="healthy" or env.portmaster_management=="system"' "$APP/love_ui/main.lua"
grep -Fq '"portmaster_management": "$(json_escape "$PAM_PORTMASTER_MANAGEMENT")"' "$DIST/APP Manager.sh"
grep -Fq 'L("Environment Management","环境管理")' "$APP/love_ui/app_environment.lua"
grep -Fq 'L("PortMaster required","需要安装 PortMaster")' "$APP/love_ui/app_environment.lua"
grep -Fq ' --check-pm-update >/dev/null 2>&1 &' "$APP/love_ui/main.lua"
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
health="$(PAM_SOURCE_DIR="$SPACED" PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  PAM_PORTKIT_BIN_OVERRIDE="$HOST_PORTKIT" PAM_NATIVE_LAUNCHER_OVERRIDE="$SPACED/APP Manager.sh" \
  bash "$SPACED/APP Manager.sh" --health-check)"
case "$health" in
  missing$'\t'*"$TMP/missing PortMaster") ;;
  *) echo "portable app: unexpected health result: $health" >&2; exit 1 ;;
esac
cat > "$TMP/appmanager-test" <<'CLI'
#!/bin/sh
if [ "${1:-}" = "fetch-stable-manifest" ]; then
  shift; out=""
  while [ "$#" -gt 0 ]; do
    case "$1" in --output) out=$2; shift 2 ;; *) shift ;; esac
  done
  printf '%s\n' called >> "$PAM_TEST_FETCH_LOG"
  printf '%s\n' '{"stable":{"md5":"00000000000000000000000000000000","url":"https://github.com/PortsMaster/PortMaster-GUI/releases/download/2026.07/PortMaster.zip","version":"2026.07"}}' > "$out"
  printf '%s\n' '{"ok":true}'
  exit 0
fi
exec "$PAM_REAL_APPMANAGER" "$@"
CLI
chmod +x "$TMP/appmanager-test"
PAM_REAL_APPMANAGER="$HOST_APPMANAGER" PAM_TEST_FETCH_LOG="$TMP/update-fetch.log" PAM_SOURCE_DIR="$SPACED" \
  PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  PAM_PORTKIT_BIN_OVERRIDE="$HOST_PORTKIT" PAM_APPMANAGER_CLI_BIN_OVERRIDE="$TMP/appmanager-test" \
  PAM_NATIVE_LAUNCHER_OVERRIDE="$SPACED/APP Manager.sh" \
  bash "$SPACED/APP Manager.sh" --check-pm-update
grep -Fq $'\tok\t2026.07' "$SPACED/jenny92-appmanager/state/portmaster-update.tsv"
first_count=$(wc -l < "$TMP/update-fetch.log" | tr -d ' ')
PAM_REAL_APPMANAGER="$HOST_APPMANAGER" PAM_TEST_FETCH_LOG="$TMP/update-fetch.log" PAM_SOURCE_DIR="$SPACED" \
  PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  PAM_PORTKIT_BIN_OVERRIDE="$HOST_PORTKIT" PAM_APPMANAGER_CLI_BIN_OVERRIDE="$TMP/appmanager-test" \
  PAM_NATIVE_LAUNCHER_OVERRIDE="$SPACED/APP Manager.sh" \
  bash "$SPACED/APP Manager.sh" --check-pm-update
[ "$(wc -l < "$TMP/update-fetch.log" | tr -d ' ')" = "$first_count" ]
PAM_REAL_APPMANAGER="$HOST_APPMANAGER" PAM_TEST_FETCH_LOG="$TMP/update-fetch.log" PAM_SOURCE_DIR="$SPACED" \
  PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  PAM_PORTKIT_BIN_OVERRIDE="$HOST_PORTKIT" PAM_APPMANAGER_CLI_BIN_OVERRIDE="$TMP/appmanager-test" \
  PAM_NATIVE_LAUNCHER_OVERRIDE="$SPACED/APP Manager.sh" \
  bash "$SPACED/APP Manager.sh" --check-pm-update-force
[ "$(wc -l < "$TMP/update-fetch.log" | tr -d ' ')" -gt "$first_count" ]
python3 - "$SPACED/jenny92-appmanager/state/env.json" <<'PY'
import json, sys
env=json.load(open(sys.argv[1], encoding="utf-8"))
assert env["update_status"] == "ok"
assert env["portmaster_latest"] == "2026.07"
PY

# Replace only the foreign-architecture executables with test doubles and run
# the real packaged launcher with no PortMaster tree or inherited PM variables.
# This proves bootstrap ordering and private-path selection on the host runner.
rm -f "$SPACED/jenny92-appmanager/runtime/love.aarch64"
ln -s /usr/bin/true "$SPACED/jenny92-appmanager/runtime/love.aarch64"
cp /usr/bin/true "$SPACED/jenny92-appmanager/bin/gptokeyb"
chmod +x "$SPACED/jenny92-appmanager/runtime/love.aarch64" "$SPACED/jenny92-appmanager/bin/gptokeyb"
xattr -c "$SPACED/jenny92-appmanager/bin/gptokeyb" 2>/dev/null || true
env -i PATH=/usr/bin:/bin HOME="$TMP/home" PAM_TOOL_MODE=system PAM_SOURCE_DIR="$SPACED" \
  PAM_PORTMASTER_DIR_OVERRIDE="$TMP/missing PortMaster" \
  PAM_PORTKIT_BIN_OVERRIDE="$HOST_PORTKIT" PAM_NATIVE_LAUNCHER_OVERRIDE="$SPACED/APP Manager.sh" \
  bash "$SPACED/APP Manager.sh"
PAM_ENV_PATH="$SPACED/jenny92-appmanager/state/env.json"
[ "$PAM_ENV_PATH" = "$SPACED/jenny92-appmanager/state/env.json" ]
python3 - "$PAM_ENV_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    env = json.load(handle)
assert env["portmaster_health"] == "missing"
assert env["app_root"].endswith("/jenny92-appmanager")
assert env["gptokeyb"].endswith("/jenny92-appmanager/bin/gptokeyb")
assert env["sdl_controller_file"].endswith("/jenny92-appmanager/share/gamecontrollerdb.txt")
assert "jenny92-appmanager" in env["ignore_dirs"]
assert "autoinstall" in env["ignore_dirs"]
assert env["device_name"] == "Generic PortMaster device"
PY

echo "appmanager portable package tests: PASS"
