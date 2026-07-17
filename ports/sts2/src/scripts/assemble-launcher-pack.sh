#!/usr/bin/env bash
# Build a full redistributable STS2 launcher dist.
#
# Normal dev flow:
#   _kit/dist_port.sh sts2
#
# Full release flow:
#   ports/sts2/src/scripts/assemble-launcher-pack.sh
#
# Output:
#   ports/sts2/dist/                 flat deployable dist
#   ports/sts2/dist-sts2-<date>.zip  optional release zip

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
DIST="$PORT_ROOT/dist"
DATA="$DIST/data_sts2_linuxbsd_arm64"

DOTNET_VERSION="${DOTNET_VERSION:-9.0.7}"
DOTNET_ARCH="${DOTNET_ARCH:-arm64}"
DOTNET_CACHE="${DOTNET_CACHE:-$PORT_ROOT/.cache/dotnet-runtime-$DOTNET_VERSION-linux-$DOTNET_ARCH}"
SKIP_DOTNET_DOWNLOAD="${SKIP_DOTNET_DOWNLOAD:-0}"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

require_file() {
  [ -f "$1" ] || { red "missing: $1"; exit 1; }
}
require_dir() {
  [ -d "$1" ] || { red "missing: $1"; exit 1; }
}

blue "=== 1. build core dist ==="
"$SRC_ROOT/scripts/dist-port.sh"

blue "=== 2. preflight release-only dependencies ==="
require_file "$SRC_ROOT/external/godot/godot.linuxbsd.template_release.arm64.mono"
require_file "$SRC_ROOT/external/godot/GodotSharp.dll"
require_file "$SRC_ROOT/external/fmod-gdextension/libGodotFmod.linux.template_release.arm64.so"
require_file "$SRC_ROOT/external/spine-runtimes/libspine_godot.linux.template_release.arm64.so"
require_file "$SRC_ROOT/refs/0Harmony.dll"
STEAM_STUB="${STEAM_STUB:-../Bogodroid/tools/steam_mock/libsteam_api64.so}"
require_file "$STEAM_STUB"
green "  release dependencies present"

blue "=== 3. .NET 9 runtime ($DOTNET_VERSION linux-$DOTNET_ARCH) ==="
if [ ! -d "$DOTNET_CACHE/shared/Microsoft.NETCore.App/$DOTNET_VERSION" ]; then
  if [ "$SKIP_DOTNET_DOWNLOAD" = "1" ]; then
    red "  cache missing + SKIP_DOTNET_DOWNLOAD=1; aborting"
    exit 1
  fi
  mkdir -p "$DOTNET_CACHE"
  URL="https://builds.dotnet.microsoft.com/dotnet/Runtime/$DOTNET_VERSION/dotnet-runtime-$DOTNET_VERSION-linux-$DOTNET_ARCH.tar.gz"
  echo "  downloading $URL"
  curl -fsSL "$URL" | tar -xz -C "$DOTNET_CACHE"
fi
BCL_DIR="$DOTNET_CACHE/shared/Microsoft.NETCore.App/$DOTNET_VERSION"
require_dir "$BCL_DIR"

blue "=== 4. add release runtime files ==="
cp "$SRC_ROOT/external/godot/godot.linuxbsd.template_release.arm64.mono" "$DIST/godot.mono"
chmod +x "$DIST/godot.mono"
cp "$SRC_ROOT/external/godot/GodotSharp.dll" "$DATA/"
cp "$SRC_ROOT/refs/0Harmony.dll" "$DATA/"
cp "$STEAM_STUB" "$DIST/libsteam_api64.so"

cp "$BCL_DIR"/*.dll "$DATA/"
cp "$BCL_DIR"/*.so "$DATA/" 2>/dev/null || true

mkdir -p "$DIST/addons/fmod/libs/linux" "$DIST/addons/spine/linux"
cp "$SRC_ROOT/external/fmod-gdextension"/*.so "$DIST/addons/fmod/libs/linux/"
cp "$SRC_ROOT/external/spine-runtimes/libspine_godot.linux.template_release.arm64.so" "$DIST/addons/spine/linux/"

blue "=== 5. verify ==="
verify_files=(
  "$DIST/Slay the Spire 2.sh"
  "$DIST/godot.mono"
  "$DIST/love_ui/main.lua"
  "$DIST/love_ui/kit.lua"
  "$DIST/love_ui/conf.lua"
  "$DIST/love_ui/ui.gptk"
  "$DIST/port_compat.pck"
  "$DIST/libsteam_api64.so"
  "$DATA/sts2_compat.dll"
  "$DATA/GodotSharp.dll"
  "$DATA/0Harmony.dll"
  "$DATA/sts2.runtimeconfig.json"
  "$DATA/System.Private.CoreLib.dll"
  "$DIST/addons/fmod/libs/linux/libGodotFmod.linux.template_release.arm64.so"
  "$DIST/addons/spine/linux/libspine_godot.linux.template_release.arm64.so"
  "$DIST/addons/sentry/SentryStub.gd"
  "$DIST/gamedata/README.md"
)
for f in "${verify_files[@]}"; do
  require_file "$f"
done
green "  ${#verify_files[@]}/${#verify_files[@]} key files present"

blue "=== 6. size report ==="
du -sh "$DIST"/* 2>/dev/null | sort -h | tail -12
du -sh "$DIST"

ZIP="$PORT_ROOT/dist-sts2-$(date +%Y%m%d).zip"
(cd "$PORT_ROOT" && zip -qr "$ZIP" dist)
green "=== ready ==="
green "  dist: $DIST"
green "  zip:     $ZIP ($(du -h "$ZIP" | awk '{print $1}'))"
