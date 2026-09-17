#!/usr/bin/env bash
# INPUT:  龙沉异世录 manifest/模板/组装与资源准备脚本、模拟 GameData
# OUTPUT: 包声明、资源路径和首次准备成功/失败/幂等断言结果
# POS:    龙沉异世录启动和玩家资源准备契约回归测试
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="$ROOT/ports/sunkendragon"
STAGE_SCRIPT="$PORT/src/scripts/stage-minimal-package.sh"
FULL_STAGE_SCRIPT="$PORT/src/scripts/stage-full-package.sh"
SETUP_SCRIPT="$PORT/patch/setup-gamedata.sh"

python3 - "$PORT/manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

assert manifest["name"] == "sunkendragon"
assert manifest["title"] == "龙沉异世录"
assert manifest["port_dir"] == "sunkendragon"
assert manifest["script"] == "L_龙沉异世录[中].sh"
assert manifest["runtime"] == "Bogodroid unityloader"
assert manifest["portmaster"]["exp"] is True
PY

for path in \
  "$PORT/love/main.lua" \
  "$PORT/love/launcher.sh.template" \
  "$PORT/config.toml.template" \
  "$PORT/GameData/README.txt" \
  "$SETUP_SCRIPT" \
  "$STAGE_SCRIPT" \
  "$FULL_STAGE_SCRIPT"
do
  [ -s "$path" ] || {
    echo "sunkendragon: missing $(basename "$path")" >&2
    exit 1
  }
done

grep -Fq 'resolve_port_toml' "$PORT/love/launcher.sh.template"
grep -Fq 'run_love_launcher_ui' "$PORT/love/launcher.sh.template"
grep -Fq 'configure_unity_display "$PORT_TOML"' "$PORT/love/launcher.sh.template"
grep -Fq 'launcher.render_scale {env = "SDR_RENDER_PERCENT"}' "$PORT/love/main.lua"
grep -Fq '"${SDR_RENDER_PERCENT:-100}" || exit 1' "$PORT/love/launcher.sh.template"
grep -Fq 'apply_button_remap' "$PORT/love/launcher.sh.template"
grep -Fq 'patch/setup-gamedata.sh' "$PORT/love/launcher.sh.template"
grep -Fq 'LD_LIBRARY_PATH="$GAMEDIR:$GAMEDIR/gamefiles/lib/arm64-v8a' "$PORT/love/launcher.sh.template"
grep -Fq 'libsdkencryptedappticket64.so' "$FULL_STAGE_SCRIPT"
grep -Fq 'run_unity_game "$PORT_TOML"' "$PORT/love/launcher.sh.template"

for core_file in \
  'gamefiles/lib/arm64-v8a/libil2cpp.so' \
  'gamefiles/lib/arm64-v8a/libunity.so' \
  'gamefiles/lib/arm64-v8a/libmain.so' \
  'gamefiles/assets/bin/Data/Managed/Metadata/global-metadata.dat' \
  'gamefiles/assets/bin/Data/globalgamemanagers' \
  'gamefiles/.gamedata_ready'
do
  grep -Fq "$core_file" "$PORT/love/main.lua"
  grep -Fq "$core_file" "$PORT/love/launcher.sh.template"
done

grep -Fq 'source_glob = "GameData/*_Data/globalgamemanagers"' "$PORT/love/main.lua"
grep -Fq 'game_files="gamefiles"' "$PORT/config.toml.template"
grep -Fq 'packageName="com.DefaultCompany.buildableproject"' "$PORT/config.toml.template"
grep -Fq '"$ROOT/_kit/dist_port.sh" sunkendragon' "$STAGE_SCRIPT"
grep -Fq 'libil2cpp.so' "$STAGE_SCRIPT"
grep -Fq 'libunity.so' "$STAGE_SCRIPT"
grep -Fq 'libmain.so' "$STAGE_SCRIPT"
grep -Fq 'global-metadata.dat' "$STAGE_SCRIPT"
for runtime_file in \
  unityloader.libs/libstdc++.so.6 \
  unityloader.libs/libgcc_s.so.1 \
  unityloader.d/android_base.so \
  unityloader.d/unity_2021_3.so \
  unityloader.d/platform_sdl_runtime.so \
  unityloader.d/sdk_unity_burst.so
do
  grep -Fq "$runtime_file" "$STAGE_SCRIPT"
  grep -Fq "$runtime_file" "$FULL_STAGE_SCRIPT"
done
if grep -Fq 'cp -R "$PAYLOAD/."' "$STAGE_SCRIPT"; then
  echo "sunkendragon: minimal package script still copies the full Android payload" >&2
  exit 1
fi
grep -Fq '"$ROOT/_kit/dist_port.sh" sunkendragon' "$FULL_STAGE_SCRIPT"
grep -Fq 'cp -R "$PAYLOAD/."' "$FULL_STAGE_SCRIPT"
grep -Fq 'libsteam_api64.so' "$FULL_STAGE_SCRIPT"
grep -Fq 'full-android-baseline' "$FULL_STAGE_SCRIPT"

bash -n "$PORT/love/launcher.sh.template"
bash -n "$SETUP_SCRIPT"
bash -n "$STAGE_SCRIPT"
bash -n "$FULL_STAGE_SCRIPT"

# Exercise missing, invalid, successful and idempotent GameData preparation.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/port"
mkdir -p \
  "$FIXTURE/gamefiles/lib/arm64-v8a" \
  "$FIXTURE/gamefiles/assets/bin/Data/Managed/Metadata" \
  "$FIXTURE/GameData"
printf runtime > "$FIXTURE/gamefiles/lib/arm64-v8a/libil2cpp.so"
printf runtime > "$FIXTURE/gamefiles/lib/arm64-v8a/libunity.so"
printf runtime > "$FIXTURE/gamefiles/lib/arm64-v8a/libmain.so"
printf metadata > "$FIXTURE/gamefiles/assets/bin/Data/Managed/Metadata/global-metadata.dat"
printf assemblies > "$FIXTURE/gamefiles/assets/bin/Data/ScriptingAssemblies.json"
printf initialize > "$FIXTURE/gamefiles/assets/bin/Data/RuntimeInitializeOnLoads.json"
printf guid > "$FIXTURE/gamefiles/assets/bin/Data/unity_app_guid"

if GAMEDIR="$FIXTURE" "$SETUP_SCRIPT" >/dev/null 2>&1; then
  echo "sunkendragon: missing GameData unexpectedly succeeded" >&2
  exit 1
fi

mkdir -p "$FIXTURE/GameData/Sunken Dragon_Data"
printf 'not this game\n' > "$FIXTURE/GameData/Sunken Dragon_Data/app.info"
if GAMEDIR="$FIXTURE" "$SETUP_SCRIPT" >/dev/null 2>&1; then
  echo "sunkendragon: incomplete GameData unexpectedly succeeded" >&2
  exit 1
fi

for file in "Sunken Dragon.exe" GameAssembly.dll UnityPlayer.dll; do
  printf windows > "$FIXTURE/GameData/$file"
done
DATA="$FIXTURE/GameData/Sunken Dragon_Data"
printf 'Pocket Game\nSunken Dragon\n' > "$DATA/app.info"
printf managers > "$DATA/globalgamemanagers"
printf scene > "$DATA/level0"
printf assets > "$DATA/resources.assets"
printf assemblies > "$DATA/ScriptingAssemblies.json"
printf 'gfx-enable-gfx-jobs=1\nsingle-instance=\nnolog=\n' > "$DATA/boot.config"
mkdir -p "$DATA/Resources" "$DATA/il2cpp_data/Metadata" "$DATA/il2cpp_data/Resources"
printf builtin > "$DATA/Resources/unity_builtin_extra"
printf windows_metadata > "$DATA/il2cpp_data/Metadata/global-metadata.dat"
printf resources > "$DATA/il2cpp_data/Resources/mscorlib.dll-resources.dat"

GAMEDIR="$FIXTURE" "$SETUP_SCRIPT" >/dev/null
test -s "$FIXTURE/gamefiles/.gamedata_ready"
test -s "$FIXTURE/gamefiles/assets/bin/Data/globalgamemanagers"
test -s "$FIXTURE/gamefiles/assets/bin/Data/Managed/Metadata/global-metadata.dat"
test -s "$FIXTURE/conf/il2cpp/Metadata/global-metadata.dat"
test -s "$FIXTURE/conf/il2cpp/unity.ver"
test -s "$FIXTURE/GameData/GameAssembly.dll"
test ! -e "$FIXTURE/gamefiles/assets/bin/Data/il2cpp_data"
test ! -e "$FIXTURE/gamefiles/assets/bin/Data/Plugins"
grep -Fq 'androidStartInFullscreen=1' "$FIXTURE/gamefiles/assets/bin/Data/boot.config"

# A completed migration is a no-op and leaves the player-owned source intact.
GAMEDIR="$FIXTURE" "$SETUP_SCRIPT" | grep -Fq 'already prepared'
test -s "$FIXTURE/GameData/Sunken Dragon_Data/globalgamemanagers"

# Game/runtime payloads must stay out of tracked source. Generated dist is
# ignored and may contain either the verified full baseline or a later
# explicitly selected minimal experiment.
if [ -e "$PORT/gamefiles" ] || [ -e "$PORT/unityloader" ]; then
  echo "sunkendragon: runtime payload leaked into tracked source tree" >&2
  exit 1
fi

echo "sunkendragon launcher tests passed"
