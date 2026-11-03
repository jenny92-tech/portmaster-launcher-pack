#!/usr/bin/env bash
# INPUT:  Bogodroid ARM64 核心文件、unityloader/插件、支持文件与 _kit 打包工具
# OUTPUT: 待玩家填充 GameData 的最小运行包与 PAYLOAD-SHA256.txt
# POS:    龙沉异世录不包含可复用 Windows 游戏资源的最小包组装脚本
# Build the minimal 龙沉异世录 PortMaster package.
#
# The package carries only the ARM64 runtime outputs that cannot come from the
# Windows release. Players supply the complete Windows game in GameData/.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
PORT="$ROOT/ports/sunkendragon"
BOGODROID_ROOT="${1:-$ROOT/../Bogodroid}"
PAYLOAD="${2:-$BOGODROID_ROOT/tools/unity_convert/work/bogodroid-gamefiles}"
LOADER="${3:-$BOGODROID_ROOT/build-log/unityloader}"
SUPPORT_FILES="${4:-$BOGODROID_ROOT/gamefiles/support_files}"
DIST="$PORT/dist"
LOADER_DIR="$(dirname "$LOADER")"
UNITYLOADER_PLUGINS=(
  android_base
  unity_2021_3
  platform_sdl_runtime
  sdk_unity_burst
)

# The repository build helper imports stdlib tomllib (Python 3.11+). macOS may
# put its older system Python first, so prefer an installed modern interpreter.
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
  gamedata/lib/arm64-v8a/libil2cpp.so \
  gamedata/lib/arm64-v8a/libunity.so \
  gamedata/lib/arm64-v8a/libmain.so \
  gamedata/assets/bin/Data/Managed/Metadata/global-metadata.dat \
  gamedata/assets/bin/Data/ScriptingAssemblies.json \
  gamedata/assets/bin/Data/RuntimeInitializeOnLoads.json \
  gamedata/assets/bin/Data/unity_app_guid
do
  source_path="$PAYLOAD/${core_file#gamedata/}"
  [ -s "$source_path" ] || {
    echo "missing converted core file: $source_path" >&2
    exit 1
  }
done

[ -x "$LOADER" ] || {
  echo "missing executable unityloader: $LOADER" >&2
  exit 1
}
case "$(file "$LOADER")" in
  *ELF*ARM\ aarch64*) ;;
  *)
    echo "unityloader is not an ARM64 Linux ELF: $LOADER" >&2
    exit 1
    ;;
esac
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
  "$DIST/gamefiles/lib/arm64-v8a" \
  "$DIST/gamefiles/assets/bin/Data/Managed/Metadata" \
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
cp "$PAYLOAD/lib/arm64-v8a/libil2cpp.so" "$DIST/gamefiles/lib/arm64-v8a/"
cp "$PAYLOAD/lib/arm64-v8a/libunity.so" "$DIST/gamefiles/lib/arm64-v8a/"
cp "$PAYLOAD/lib/arm64-v8a/libmain.so" "$DIST/gamefiles/lib/arm64-v8a/"
cp "$PAYLOAD/assets/bin/Data/Managed/Metadata/global-metadata.dat" \
  "$DIST/gamefiles/assets/bin/Data/Managed/Metadata/"
cp "$PAYLOAD/assets/bin/Data/ScriptingAssemblies.json" \
  "$DIST/gamefiles/assets/bin/Data/ScriptingAssemblies.json"
cp "$PAYLOAD/assets/bin/Data/RuntimeInitializeOnLoads.json" \
  "$DIST/gamefiles/assets/bin/Data/RuntimeInitializeOnLoads.json"
cp "$PAYLOAD/assets/bin/Data/unity_app_guid" \
  "$DIST/gamefiles/assets/bin/Data/unity_app_guid"
cp -R "$SUPPORT_FILES/." "$DIST/support_files/"
cp "$PORT/GameData/README.txt" "$DIST/GameData/README.txt"
cp "$PORT/patch/setup-gamedata.sh" "$DIST/patch/setup-gamedata.sh"
chmod a+x "$DIST/patch/setup-gamedata.sh"

{
  echo "# 龙沉异世录 minimal runtime checksums"
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
      gamefiles/lib/arm64-v8a/libil2cpp.so \
      gamefiles/lib/arm64-v8a/libunity.so \
      gamefiles/lib/arm64-v8a/libmain.so \
      gamefiles/assets/bin/Data/Managed/Metadata/global-metadata.dat
  )
} > "$DIST/PAYLOAD-SHA256.txt"

echo ">>> staged minimal 龙沉异世录 package -> $DIST"
du -sh "$DIST"
