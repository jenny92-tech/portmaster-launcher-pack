#!/bin/sh
# INPUT:  私有 runtime.ext4、runtime_mount.py、ARM64 Linux、Box64/Wine 与 Wayland
# OUTPUT: --prepare/--box64/--wineserver 或显式 Windows 程序启动入口
# POS:    为掌机 Wine 原型挂载并隔离运行库、prefix、用户目录和缓存
set -eu
if [ -z "${1:-}" ]; then
    echo 'No Windows program selected; choose a game in the launcher.' >&2
    exit 64
fi
APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE=${WINE_RUNNER_HOME:-$APP_ROOT}
ROOT=${WINE_RUNNER_MOUNT:-/tmp/wine-runner}
IMAGE="$BASE/runtime.ext4"
[ "$(uname -m)" = aarch64 ] || { echo 'This runtime requires ARM64 Linux.' >&2; exit 1; }
: "${WINE_RUNNER_PYTHON:?Start this game through the Wine launcher entry.}"
"$WINE_RUNNER_PYTHON" "$APP_ROOT/runtime_install.py" --base "$BASE" --mount-existing "$ROOT"
WINE_ROOT="$ROOT/runtime/wine-10.0-amd64-wow64"
[ -x "$ROOT/runtime/bin/box64" ] && [ -f "$WINE_ROOT/bin/wine" ] || {
    echo 'Wine installation is incomplete.' >&2; exit 1;
}
mkdir -p "$ROOT/home" "$ROOT/logs" "$ROOT/prefixes"
[ "${1:-}" != --prepare ] || exit 0
export HOME="$ROOT/home"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
unset DISPLAY
export WINEPREFIX="$ROOT/prefixes/default"
export WINEARCH=win64
export WINELOADER="$WINE_ROOT/bin/wine"
export WINESERVER="$WINE_ROOT/bin/wineserver"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d;mscoree,mshtml=}"
export WINEDEBUG="${WINEDEBUG:--all}"
export BOX64_PATH="$WINE_ROOT/bin:$ROOT/runtime/bin"
export BOX64_LD_LIBRARY_PATH="$WINE_ROOT/lib/wine/x86_64-unix:$ROOT/runtime/x86-libs/usr/lib/box64-x86_64-linux-gnu"
export LD_LIBRARY_PATH="$ROOT/runtime/native-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export BOX64_LOG="${BOX64_LOG:-0}"
export BOX64_NOBANNER="${BOX64_NOBANNER:-1}"
export PATH="$ROOT/runtime/bin:$WINE_ROOT/bin:$PATH"
case "${1:-}" in
    --box64) shift; exec "$ROOT/runtime/bin/box64" "$@" ;;
    --wineserver) shift; exec "$ROOT/runtime/bin/box64" "$WINE_ROOT/bin/wineserver" "$@" ;;
esac
exec "$ROOT/runtime/bin/box64" "$WINE_ROOT/bin/wine" "$@"
