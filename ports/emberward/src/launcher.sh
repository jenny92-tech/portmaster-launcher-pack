#!/bin/bash
# INPUT:  PortMaster Godot 4.3/Weston、emberward.pck、按键映射与私有图形兼容库
# OUTPUT: 沿用 emberward/conf 的游戏进程及会话资源清理
# POS:    余烬灯塔的原生 Wayland 与 Weston/Crusty 启动模板
# PORTMASTER: emberward, Je-余烬灯塔.sh
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH##*/}" = sh ]; then
    exec /bin/bash "$0" "$@"
fi
#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/portmaster_bootstrap.sh"
source "$KIT/launcher_platform.sh"
source "$KIT/launcher_artwork.sh"
#@KIT-END
# Emberward / PortMaster. Shared runtimes stay managed by PortMaster.
set -o pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
GAMEDIR="$SCRIPT_DIR/emberward"

# File-only package check; never applies a staged update or mounts a runtime.
if [ "${1:-}" = --check ]; then
    for input in emberward.pck emberward.gptk compat/loong-egl-compat.so \
        compat/vulkan-wsi/libVkLayer_window_system_integration.so compat/vulkan-wsi/layer-template.json; do
        [ -r "$GAMEDIR/$input" ] || { echo "Missing Emberward input: $GAMEDIR/$input" >&2; exit 1; }
    done
    printf '%s\n' 'Emberward preflight passed; game was not started.'
    exit 0
fi

# Apply a verified upload only before starting Godot. Godot4.3 reopens the PCK
# for uncached resources, so renaming a live pack is not a safe hot update.
apply_staged_update() {
    local marker="$SCRIPT_DIR/.emberward-pending"
    [ -f "$marker" ] || return 0
    if pidof godot43.aarch64 godot43.armhf godot43.x86_64 >/dev/null 2>&1; then
        echo "Emberward is still running; the staged update was preserved."
        return 1
    fi
    local pending_release pending_root backup_root name pending_files
    IFS= read -r pending_release < "$marker"
    [[ "$pending_release" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || return 1
    pending_root="$SCRIPT_DIR/.emberward-update-$pending_release/lan-coop"
    backup_root="$SCRIPT_DIR/.emberward-backup/$pending_release/lan-coop/emberward"
    [ -f "$pending_root/pending.sha256" ] || return 1
    (cd "$pending_root" && sha256sum -c pending.sha256) || return 1
    pending_files="emberward.pck emberward.gptk README.md"
    if [ -d "$pending_root/emberward/compat/vulkan-wsi" ]; then
        pending_files="$pending_files compat/vulkan-wsi/libVkLayer_window_system_integration.so compat/vulkan-wsi/layer-template.json compat/vulkan-wsi/LICENSE compat/vulkan-wsi/source.json"
    fi
    for name in $pending_files; do
        [ -f "$pending_root/emberward/$name" ] || return 1
    done
    mkdir -p "$backup_root" || return 1
    for name in $pending_files; do
        if cmp -s "$GAMEDIR/$name" "$pending_root/emberward/$name"; then continue; fi
        mkdir -p "$(dirname "$backup_root/$name")" "$(dirname "$GAMEDIR/$name")" || return 1
        if [ ! -f "$backup_root/$name" ] && [ -f "$GAMEDIR/$name" ]; then
            cp "$GAMEDIR/$name" "$backup_root/$name" || return 1
        fi
        cp "$pending_root/emberward/$name" "$GAMEDIR/$name.incoming-$pending_release" || return 1
        chmod 644 "$GAMEDIR/$name.incoming-$pending_release" || return 1
        mv -f "$GAMEDIR/$name.incoming-$pending_release" "$GAMEDIR/$name" || return 1
    done
    (cd "$SCRIPT_DIR" && sha256sum -c "$pending_root/pending.sha256") || return 1
    sync
    mv "$marker" "$pending_root/applied" || return 1
}
apply_staged_update || exit 1

[ -f "$GAMEDIR/emberward.pck" ] || { echo "Supply emberward/emberward.pck before launching." >&2; exit 1; }

portmaster_init "$SCRIPT_DIR" || exit 1
portmaster_sync_launcher_artwork "$SCRIPT_DIR" "$0" "$GAMEDIR"
cd "$GAMEDIR" || exit 1
exec > "$GAMEDIR/log.txt" 2>&1
#@BUILD-LOG
mkdir -p "$GAMEDIR/conf" "$GAMEDIR/runtime" "$GAMEDIR/weston"
export XDG_DATA_HOME="$GAMEDIR/conf"
export XDG_CONFIG_HOME="$GAMEDIR/conf"
# Preserve get_controls' device-specific/user mapping; older SDL versions also
# accept its inline form, while newer ones can load the selected file directly.
export SDL_GAMECONTROLLERCONFIG_FILE="${SDL_GAMECONTROLLERCONFIG_FILE:-$controlfolder/gamecontrollerdb.txt}"
if [ -n "${sdl_controllerconfig:-}" ]; then export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"; fi
export GODOT_SILENCE_ROOT_WARNING=1
DEVICE_ARCH="${DEVICE_ARCH:-aarch64}"
case "$DEVICE_ARCH" in aarch64|armhf|x86_64) ;; *) echo "Unsupported architecture: $DEVICE_ARCH"; exit 1;; esac
GODOT_RUNTIME="godot_4.3.squashfs"
GODOT_EXECUTABLE="godot43.$DEVICE_ARCH"
mapper_pid=""
godot_mounted=0
weston_mounted=0

ensure_runtime() {
    if [ ! -f "$controlfolder/libs/$1" ]; then
        if [ ! -f "$controlfolder/harbourmaster" ]; then
            echo "Missing $1. Install it through PortMaster's Runtime Manager."
            return 1
        fi
        $ESUDO "$controlfolder/harbourmaster" --quiet --no-check runtime_check "$1" || return 1
    fi
}

cleanup() {
    if [ -n "$mapper_pid" ]; then
        # Consult our own child-job table; never signal a reused system PID.
        if jobs -pr | grep -qx "$mapper_pid"; then kill "$mapper_pid" 2>/dev/null || true; fi
        wait "$mapper_pid" 2>/dev/null || true
    fi
    if [ "$weston_mounted" = 1 ]; then $ESUDO umount "$GAMEDIR/weston" 2>/dev/null || true; fi
    if [ "$godot_mounted" = 1 ]; then $ESUDO umount "$GAMEDIR/runtime" 2>/dev/null || true; fi
}
trap cleanup EXIT
ensure_runtime "$GODOT_RUNTIME" || exit 1
if ! mountpoint -q "$GAMEDIR/runtime"; then
    $ESUDO mount -o loop,ro "$controlfolder/libs/$GODOT_RUNTIME" "$GAMEDIR/runtime" || exit 1
    godot_mounted=1
fi
GODOT_BIN="$GAMEDIR/runtime/$GODOT_EXECUTABLE"
if [ ! -x "$GODOT_BIN" ]; then echo "Godot runtime architecture mismatch: $GODOT_BIN"; exit 1; fi

# SD cards may be mounted noexec. Keep hash-addressed copies of only this
# port's executable helpers under a private, executable temporary directory.
# Existing mapped files are never rewritten; a changed helper gets a new path.
stage_executable() {
    local source_file="$1"
    local basename_value="$2"
    local digest cache_root cache_dir destination
    digest="$(sha256sum "$source_file" | cut -d ' ' -f 1)" || return 1
    [ "${#digest}" = 64 ] || return 1
    cache_root="/tmp/emberward-exec-$(id -u)"
    [ ! -L "$cache_root" ] || return 1
    mkdir -p -m 700 "$cache_root" || return 1
    [ -O "$cache_root" ] || return 1
    cache_dir="$cache_root/$digest"
    [ ! -L "$cache_dir" ] || return 1
    mkdir -p -m 700 "$cache_dir" || return 1
    destination="$cache_dir/$basename_value"
    if [ ! -f "$destination" ] || ! cmp -s "$source_file" "$destination"; then
        cp "$source_file" "$cache_dir/.stage.$$" || return 1
        [ "$(sha256sum "$cache_dir/.stage.$$" | cut -d ' ' -f 1)" = "$digest" ] || return 1
        chmod 755 "$cache_dir/.stage.$$" || return 1
        mv -f "$cache_dir/.stage.$$" "$destination" || return 1
    fi
    [ -x "$destination" ] || return 1
    printf '%s\n' "$destination"
}

loong_compat_dir=""
if [ "$DEVICE_ARCH" = aarch64 ] && [ -f /usr/lib/libmali.so.1.9.0 ] && {
    [ "${param_device:-}" = miniloong ] || [ -e /dev/input/by-path/platform-loong1_joypad-event-joystick ];
}; then
    compat_binary="$(stage_executable "$GAMEDIR/compat/loong-egl-compat.so" loong-egl-compat.so)" || exit 1
    loong_compat_dir="$(dirname "$compat_binary")"
    # Both aliases MUST refer to one DSO instance for the legacy window handle.
    for alias_name in libEGL.so.1 libwayland-egl.so.1; do
        if [ "$(readlink "$loong_compat_dir/$alias_name" 2>/dev/null)" != loong-egl-compat.so ]; then
            ln -sfn loong-egl-compat.so "$loong_compat_dir/$alias_name" || exit 1
        fi
    done
fi

prepare_vulkan_wsi() {
    local wsi="$GAMEDIR/compat/vulkan-wsi" wsi_binary manifest_dir
    [ -f "$wsi/layer-template.json" ] || return 1
    wsi_binary="$(stage_executable "$wsi/libVkLayer_window_system_integration.so" libVkLayer_window_system_integration.so)" || return 1
    # The validated stock WSI is headless-only. Add an app-owned layer without
    # changing XDG_DATA_HOME (which owns existing saves), ICDs or system files.
    manifest_dir="$XDG_DATA_HOME/vulkan/implicit_layer.d"
    mkdir -p "$manifest_dir" || return 1
    sed "s|@EMBERWARD_WSI_LIBRARY@|$wsi_binary|g" "$wsi/layer-template.json" > "$manifest_dir/emberward-wayland.json.incoming" || return 1
    mv -f "$manifest_dir/emberward-wayland.json.incoming" "$manifest_dir/emberward-wayland.json" || return 1
}

miniloong_vulkan_board_supported() {
    [ "$DEVICE_ARCH" = aarch64 ] || return 1
    [ -r /proc/device-tree/compatible ] && [ -r /proc/device-tree/model ] || return 1
    tr '\000' '\n' < /proc/device-tree/compatible | grep -Fxq 'rockchip,rk3566-rk817-tablet' || return 1
    [ "$(tr -d '\000' < /proc/device-tree/model)" = 'Rockchip RK3566 RK817 MINILOONG LP4X Board' ]
}

probe_vulkan_summary() {
    # Metadata only. The probe cannot connect to a display or create a window.
    if [ "$1" = private ]; then
        env DISPLAY= WAYLAND_DISPLAY= XDG_RUNTIME_DIR=/tmp/emberward-no-display \
            DISABLE_WSI_LAYER=1 EMBERWARD_VULKAN_WSI=1 \
            timeout 8 vulkaninfo --summary > "$vulkan_report" 2>&1 || return 1
    else
        env DISPLAY= WAYLAND_DISPLAY= XDG_RUNTIME_DIR=/tmp/emberward-no-display \
            EMBERWARD_VULKAN_WSI=0 \
            timeout 8 vulkaninfo --summary > "$vulkan_report" 2>&1 || return 1
    fi
    grep -Eq 'deviceName[[:space:]]*=[[:space:]]*Mali-G52[[:space:]]*$' "$vulkan_report"
}

select_vulkan_path() {
    vulkan_mode=""
    miniloong_vulkan_board_supported || return 1
    command -v timeout >/dev/null 2>&1 && command -v vulkaninfo >/dev/null 2>&1 || return 1
    timeout 8 "$GODOT_BIN" --help 2>/dev/null | grep -Eq 'wayland.*vulkan' || return 1
    vulkan_report="/tmp/emberward-vulkan-probe-$(id -u).log"
    probe_vulkan_summary native || return 1
    if grep -Eq '^[[:space:]]*VK_KHR_wayland_surface[[:space:]]' "$vulkan_report"; then
        vulkan_mode=native
        return 0
    fi
    # Only the stock g13p0 ABI was validated with this private adapter. A
    # different firmware may provide its own native WSI, or stays on GLES.
    grep -Eq 'driverInfo[[:space:]]*=[[:space:]]*v1\.g13p0-01eac0\.' "$vulkan_report" || return 1
    prepare_vulkan_wsi || return 1
    probe_vulkan_summary private || return 1
    grep -Eq '^[[:space:]]*VK_KHR_wayland_surface[[:space:]]' "$vulkan_report" || return 1
    vulkan_mode=private
}

# Six dedicated keyboard tokens keep A/B/X/Y/START/SELECT independently calibratable.
# Ignore raw gamepad input in Godot while gptokeyb is active, avoiding double presses.
unset EMBERWARD_MAPPED_INPUT
if [ -f "$controlfolder/gptokeyb" ] && [ -r "$controlfolder/gptokeyb" ]; then
    mapper_binary="$(stage_executable "$controlfolder/gptokeyb" gptokeyb)" || exit 1
    "$mapper_binary" "$GODOT_EXECUTABLE" -c "$GAMEDIR/emberward.gptk" &
    mapper_pid=$!
    sleep .1
    if kill -0 "$mapper_pid" 2>/dev/null; then
        export EMBERWARD_MAPPED_INPUT=1
    else
        wait "$mapper_pid" 2>/dev/null || true
        mapper_pid=""
    fi
fi

if [ -S "${XDG_RUNTIME_DIR:-/run}/${WAYLAND_DISPLAY:-wayland-0}" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run}"
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    vulkan_mode=""
    renderer="${EMBERWARD_RENDERER:-auto}"
    if [ -r "$GAMEDIR/renderer.cfg" ]; then IFS= read -r renderer < "$GAMEDIR/renderer.cfg"; fi
    case "$renderer" in
        auto)
            renderer=gles
            if select_vulkan_path; then renderer=vulkan; fi
            ;;
        gles|vulkan) ;;
        *) echo "Invalid game renderer selection: $renderer"; exit 1 ;;
    esac
    if [ "$renderer" = vulkan ]; then
        if [ -z "$vulkan_mode" ]; then select_vulkan_path || { echo "Vulkan is unavailable for this hardware/runtime/driver combination."; exit 1; }; fi
        unset EMBERWARD_VULKAN_WSI
        if [ "$vulkan_mode" = private ]; then
            export DISABLE_WSI_LAYER=1
            export EMBERWARD_VULKAN_WSI=1
        fi
        echo "Emberward: Vulkan Mobile on native Wayland; $vulkan_mode WSI, existing system ICD."
        "$GODOT_BIN" --display-driver wayland --rendering-method mobile --rendering-driver vulkan \
            --single-window --main-pack "$GAMEDIR/emberward.pck" --fullscreen "$@"
        exit $?
    fi
    unset EMBERWARD_VULKAN_WSI
    if [ -n "$loong_compat_dir" ]; then
        env LD_LIBRARY_PATH="$loong_compat_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
            "$GODOT_BIN" --display-driver wayland --rendering-method gl_compatibility --rendering-driver opengl3_es \
            --single-window --main-pack "$GAMEDIR/emberward.pck" --fullscreen "$@"
    else
        "$GODOT_BIN" --display-driver wayland --rendering-method gl_compatibility --rendering-driver opengl3_es --main-pack "$GAMEDIR/emberward.pck" --fullscreen "$@"
    fi
    exit $?
fi

# Canonical PortMaster WestonPack path for firmware without a native compositor.
ensure_runtime "weston_pkg_0.2.squashfs" || exit 1
if ! mountpoint -q "$GAMEDIR/weston"; then
    $ESUDO mount -o loop,ro "$controlfolder/libs/weston_pkg_0.2.squashfs" "$GAMEDIR/weston" || exit 1
    weston_mounted=1
fi
# Stock TrimUI's GL4ES EGL shim conflicts with Weston's Mesa libGL stub.
# Xwayland only supplies window/input metadata in this headless mode; keep it
# on SHM so it never probes EGL. Crusty still renders the game through SDL/GLES.
if [ "$DEVICE_ARCH" = aarch64 ] && [ -f /usr/lib/libmali.so.0 ] && \
        [ -f /usr/lib/libEGL.so.1 ] && [ -f /mnt/SDCARD/System/lib/libEGL.so.1 ]; then
    xwayland_helper="$(stage_executable "$GAMEDIR/compat/xwayland-shm.sh" xwayland-shm.sh)" || exit 1
    export WESTON_CONFIG="$(dirname "$xwayland_helper")/weston-headless.ini"
    cat "$GAMEDIR/weston/weston.ini" > "$WESTON_CONFIG.incoming" || exit 1
    printf '\n[xwayland]\npath=%s\n' "$xwayland_helper" >> "$WESTON_CONFIG.incoming" || exit 1
    mv -f "$WESTON_CONFIG.incoming" "$WESTON_CONFIG" || exit 1
    export EMBERWARD_XWAYLAND="$GAMEDIR/weston/bin/Xwayland"
    echo "Using Xwayland SHM for window metadata; Crusty keeps game GLES rendering."
fi
$ESUDO env CRUSTY_BLOCK_INPUT=1 "$GAMEDIR/weston/westonwrap.sh" headless noop kiosk crusty_x11egl \
    XDG_DATA_HOME="$GAMEDIR/conf" "$GODOT_BIN" --display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3_es \
    --audio-driver ALSA --main-pack "$GAMEDIR/emberward.pck" --fullscreen "$@"
exit $?
