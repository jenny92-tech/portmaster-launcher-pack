#!/bin/sh

APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/LOVE-lite" && pwd)"
LOG="$APP_DIR/log.txt"

export SDL_GAMECONTROLLERCONFIG_FILE="$APP_DIR/gamecontrollerdb.txt"
export LOVE_LITE_CONFIRM_BUTTON="${LOVE_LITE_CONFIRM_BUTTON:-a}"

wayland_display="${WAYLAND_DISPLAY:-wayland-0}"
for runtime_dir in "${XDG_RUNTIME_DIR:-}" /run "/run/user/$(id -u 2>/dev/null)" /var/run; do
    [ -n "$runtime_dir" ] || continue
    if [ -S "$runtime_dir/$wayland_display" ]; then
        export XDG_RUNTIME_DIR="$runtime_dir"
        export WAYLAND_DISPLAY="$wayland_display"
        export SDL_VIDEODRIVER=wayland
        break
    fi
    if [ -S "$runtime_dir/wayland-0" ]; then
        export XDG_RUNTIME_DIR="$runtime_dir"
        export WAYLAND_DISPLAY=wayland-0
        export SDL_VIDEODRIVER=wayland
        break
    fi
done

cd "$APP_DIR" || exit 1
exec ./love-lite.aarch64 demo 960 720 >"$LOG" 2>&1
