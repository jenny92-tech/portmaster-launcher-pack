#!/usr/bin/env bash
# INPUT:  Bogodroid 完整 Android payload、unityloader/插件、Steam stub 与 _kit 打包工具
# OUTPUT: 完整 Android 基线 dist/ 包与 PAYLOAD-SHA256.txt
# POS:    龙沉异世录硬件验证用完整资源基线包的组装脚本
# Build the verified full Android baseline package for 龙沉异世录.
#
# This is intentionally the default staging path until the game is proven
# stable on target hardware. File-removal and Windows-resource migration are
# separate follow-up experiments performed only after this baseline works.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
PORT="$ROOT/ports/sunkendragon"
BOGODROID_ROOT="${1:-$ROOT/../Bogodroid}"
PAYLOAD="${2:-$BOGODROID_ROOT/tools/unity_convert/work/bogodroid-gamefiles}"
LOADER="${3:-$BOGODROID_ROOT/build-log/unityloader}"
STEAM_STUB="${4:-$BOGODROID_ROOT/tools/steam_mock/libsteam_api64.so}"
TICKET_STUB="${5:-$BOGODROID_ROOT/tools/steam_mock/libsdkencryptedappticket64.so}"
SUPPORT_FILES="${6:-$BOGODROID_ROOT/gamefiles/support_files}"
DIST="$PORT/dist"
LOADER_DIR="$(dirname "$LOADER")"
UNITYLOADER_PLUGINS=(
  android_base
  unity_2021_3
  platform_sdl_runtime
  sdk_unity_burst
)

if ! python3 -c 'import tomllib' >/dev/null 2>&1; then
  MODERN_PYTHON=""
  for python_name in python3.14 python3.13 python3.12 python3.11; do
    python_path="$(command -v "$python_name" 2>/dev/null || true)"
    if [ -n "$python_path" ] && "$python_path" -c 'import tomllib' >/dev/null 2>&1; then
      MODERN_PYTHON="$python_path"
      break
    fi
  done
  [ -n "$MODERN_PYTHON" ] || {
    echo "Python 3.11+ is required to build the launcher package" >&2
    exit 1
  }
  PATH="$(dirname "$MODERN_PYTHON"):$PATH"
  export PATH
fi

for core_file in \
  lib/arm64-v8a/libil2cpp.so \
  lib/arm64-v8a/libunity.so \
  lib/arm64-v8a/libmain.so \
  assets/bin/Data/Managed/Metadata/global-metadata.dat \
  assets/bin/Data/globalgamemanagers
do
  [ -s "$PAYLOAD/$core_file" ] || {
    echo "missing full Android payload file: $PAYLOAD/$core_file" >&2
    exit 1
  }
done

for executable in "$LOADER" "$STEAM_STUB" "$TICKET_STUB"; do
  [ -s "$executable" ] || {
    echo "missing ARM64 runtime: $executable" >&2
    exit 1
  }
  case "$(file "$executable")" in
    *ELF*ARM\ aarch64*) ;;
    *)
      echo "runtime is not an ARM64 Linux ELF: $executable" >&2
      exit 1
      ;;
  esac
done
for runtime_library in libstdc++.so.6 libgcc_s.so.1; do
  [ -s "$LOADER_DIR/unityloader.libs/$runtime_library" ] || {
    echo "missing unityloader private library: $LOADER_DIR/unityloader.libs/$runtime_library" >&2
    exit 1
  }
done
for plugin in "${UNITYLOADER_PLUGINS[@]}"; do
  [ -s "$LOADER_DIR/unityloader.d/$plugin.so" ] || {
    echo "missing unityloader plugin: $LOADER_DIR/unityloader.d/$plugin.so" >&2
    exit 1
  }
done

for support_file in cpu_present.txt cpu_possible.txt cpuinfo.txt libc.so; do
  [ -s "$SUPPORT_FILES/$support_file" ] || {
    echo "missing Bogodroid support file: $SUPPORT_FILES/$support_file" >&2
    exit 1
  }
done

"$ROOT/_kit/dist_port.sh" sunkendragon

mkdir -p \
  "$DIST/gamefiles" \
  "$DIST/support_files" \
  "$DIST/GameData" \
  "$DIST/patch" \
  "$DIST/conf" \
  "$DIST/cache" \
  "$DIST/unityloader.libs" \
  "$DIST/unityloader.d"
cp "$PORT/config.toml.template" "$DIST/config.toml"
cp "$LOADER" "$DIST/unityloader"
chmod a+x "$DIST/unityloader"
cp "$LOADER_DIR/unityloader.libs/libstdc++.so.6" \
  "$LOADER_DIR/unityloader.libs/libgcc_s.so.1" \
  "$DIST/unityloader.libs/"
for plugin in "${UNITYLOADER_PLUGINS[@]}"; do
  cp "$LOADER_DIR/unityloader.d/$plugin.so" "$DIST/unityloader.d/"
done
# APFS clone copies avoid consuming another full payload on development Macs.
# Other platforms fall back to a normal recursive copy.
if ! cp -cR "$PAYLOAD/." "$DIST/gamefiles/" 2>/dev/null; then
  cp -R "$PAYLOAD/." "$DIST/gamefiles/"
fi
cp "$STEAM_STUB" "$DIST/libsteam_api64.so"
cp "$STEAM_STUB" "$DIST/gamefiles/lib/arm64-v8a/libsteam_api64.so"
cp "$TICKET_STUB" "$DIST/libsdkencryptedappticket64.so"
cp "$TICKET_STUB" "$DIST/gamefiles/lib/arm64-v8a/libsdkencryptedappticket64.so"
cp -R "$SUPPORT_FILES/." "$DIST/support_files/"
cp "$PORT/GameData/README.txt" "$DIST/GameData/README.txt"
cp "$PORT/patch/setup-gamedata.sh" "$DIST/patch/setup-gamedata.sh"
chmod a+x "$DIST/patch/setup-gamedata.sh"
printf '%s\n' full-android-baseline > "$DIST/gamefiles/.gamedata_ready"

{
  echo "# 龙沉异世录 full Android baseline checksums"
  (
    cd "$DIST"
    shasum -a 256 \
      unityloader \
      unityloader.libs/libstdc++.so.6 \
      unityloader.libs/libgcc_s.so.1 \
      unityloader.d/android_base.so \
      unityloader.d/unity_2021_3.so \
      unityloader.d/platform_sdl_runtime.so \
      unityloader.d/sdk_unity_burst.so \
      libsteam_api64.so \
      libsdkencryptedappticket64.so \
      gamefiles/lib/arm64-v8a/libil2cpp.so \
      gamefiles/lib/arm64-v8a/libunity.so \
      gamefiles/lib/arm64-v8a/libmain.so \
      gamefiles/assets/bin/Data/Managed/Metadata/global-metadata.dat
  )
} > "$DIST/PAYLOAD-SHA256.txt"

echo ">>> staged full 龙沉异世录 baseline -> $DIST"
du -sh "$DIST"
