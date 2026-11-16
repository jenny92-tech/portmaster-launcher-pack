#!/bin/bash
# INPUT: Declarative NS installation, installed PortMaster and native helper.
# OUTPUT: One owned game session with ordinary SDK initialization and cleanup.
# POS: Shell orchestrates existing platform helpers; native tools own complex operations.
# PORTMASTER: soulknight_ns, Je-元气骑士_ns.sh
#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/portmaster_bootstrap.sh"
source "$KIT/launcher_platform.sh"
source "$KIT/launcher_compat.sh"
source "$KIT/portmaster_common.sh"
#@KIT-END
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
GAMEDIR="${SOULKNIGHT_NS_INSTALLATION:-$SCRIPT_DIR}"
PORT_NAME=soulknight_ns
LOG_PREFIX='[SOULKNIGHT-NS]'
PORTKIT="${PORTKIT_LAUNCHER_BIN_OVERRIDE:-$GAMEDIR/bin/portkit-launcher}"
if [ "${1:-}" = --check ]; then
    shift
    exec "$PORTKIT" session --root "$GAMEDIR" --check "$@"
fi
probe_only=0
case "${1:-}" in --probe-graphics|--display-check) probe_only=1; shift;; esac
portmaster_init "$SCRIPT_DIR" || exit 1
export SDL_GAMECONTROLLERCONFIG_FILE="${SDL_GAMECONTROLLERCONFIG_FILE:-$controlfolder/gamecontrollerdb.txt}"
if [ -n "${sdl_controllerconfig:-}" ]; then export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"; fi
game_pid=
finish_soulknight() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$game_pid" ]; then
        kill -TERM "$game_pid" 2>/dev/null || true
        wait "$game_pid" 2>/dev/null || true
    fi
    # Some firmware pm_finish hooks exit; keep the native session's status.
    ( launcher_platform_finish )
    exit "$status"
}
trap finish_soulknight EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
profile="$("$PORTKIT" session --root "$GAMEDIR" --print-profile "$@")" || exit 1
LAUNCHER_COMPAT_LOG_DIR="$profile/logs/wayland"
probe_backend() {
    case "$1" in
        vulkan) launcher_compat_probe ns-vulkan vulkan "$GAMEDIR/runtime" SOULKNIGHT_VULKAN=1 bash "$GAMEDIR/libexec/soulknight-graphics-probe.sh" ;;
        gles) launcher_compat_probe ns-gles gles "$GAMEDIR/runtime" SOULKNIGHT_GLES=1 bash "$GAMEDIR/libexec/soulknight-gles-graphics-probe.sh" ;;
        *) echo 'Unsupported graphics backend.' >&2; return 1 ;;
    esac
}
SOUL_NS_BACKEND=vulkan
SOUL_NS_RENDER_SCALE=100
SOUL_NS_ASPECT=auto
# Normal firmware launch opens settings. Explicit CLI launches remain usable
# for scripts, retaining the same native session owner and argument checks.
explicit_graphics=0
for value in "$@"; do
    case "$value" in --backend|--render-scale|--aspect) explicit_graphics=1;; esac
done
if [ "$probe_only" = 0 ] && [ "$explicit_graphics" = 0 ]; then
    SOUL_NS_VULKAN_AVAILABLE=0; SOUL_NS_GLES_AVAILABLE=0
    if probe_backend vulkan; then
        SOUL_NS_VULKAN_AVAILABLE=1
    fi
    if probe_backend gles; then
        SOUL_NS_GLES_AVAILABLE=1
    fi
    export SOUL_NS_VULKAN_AVAILABLE SOUL_NS_GLES_AVAILABLE
    if [ "$SOUL_NS_VULKAN_AVAILABLE:$SOUL_NS_GLES_AVAILABLE" = 0:0 ]; then
        echo 'No usable graphics backend.' >&2; exit 1
    fi
    if ! launcher_platform_display; then launcher_platform_acquire_display || exit 1; fi
    run_love_launcher_ui "$GAMEDIR/love_ui"
    [ -n "$LAUNCH_ENV" ] || { echo 'Settings UI runtime is missing.' >&2; exit 1; }
    source "$LAUNCH_ENV"
fi
# Resolve the same last explicit overrides that the native CLI will consume.
option=
for value in "$@"; do
    case "$option" in
        --backend) SOUL_NS_BACKEND=$value ;;
        --render-scale) SOUL_NS_RENDER_SCALE=$value ;;
        --aspect) SOUL_NS_ASPECT=$value ;;
    esac
    option=$value
done
case "$SOUL_NS_RENDER_SCALE" in 100|75|50) ;; *) echo 'Invalid render scale.' >&2; exit 1;; esac
case "$SOUL_NS_ASPECT" in auto|4:3|16:9) ;; *) echo 'Invalid screen ratio.' >&2; exit 1;; esac
probe_backend "$SOUL_NS_BACKEND" || exit 1
width="$LAUNCHER_COMPAT_DISPLAY_WIDTH"; height="$LAUNCHER_COMPAT_DISPLAY_HEIGHT"
case "$width:$height" in *[!0-9:]*|:*|*:) echo 'Missing native display bounds.' >&2; exit 1;; esac
aspect=$SOUL_NS_ASPECT
if [ "$aspect" = auto ]; then
    aspect=16:9
    if (( 9 * width <= 14 * height )); then aspect=4:3; fi
fi
launcher_compat_describe
printf '[SOULKNIGHT-NS] output=%sx%s aspect=%s renderer=%s scale=%s%%\n' "$width" "$height" "$aspect" "$SOUL_NS_BACKEND" "$SOUL_NS_RENDER_SCALE"
if [ "$probe_only" = 1 ]; then exit 0; fi
if [ "$LAUNCHER_COMPAT_PRESENTATION" = portable ] || [ "$LAUNCHER_COMPAT_SDL_DRIVER" = kmsdrm ]; then
    audio_setup
    memory_tuning
    if [ -z "${LAUNCHER_PLATFORM_RUNNERS:-}" ]; then launcher_platform_acquire_display || exit 1; fi
fi
if [ "$LAUNCHER_COMPAT_PRESENTATION" = portable ]; then
    ( launcher_compat_exec "$PORTKIT" wayland --runtime "$GAMEDIR/runtime" \
        --weston-image "$LAUNCHER_COMPAT_WAYLAND_IMAGE" --log-dir "$profile/logs/wayland" -- \
        "$PORTKIT" session --root "$GAMEDIR" --profile "$profile" --private-wayland \
        --presentation wsi --video-driver wayland "$@" --aspect "$aspect" \
        --backend "$SOUL_NS_BACKEND" --render-scale "$SOUL_NS_RENDER_SCALE" ) &
else
    ( launcher_compat_exec "$PORTKIT" session --root "$GAMEDIR" --profile "$profile" \
        --presentation "$LAUNCHER_COMPAT_PRESENTATION" --video-driver "$LAUNCHER_COMPAT_SDL_DRIVER" \
        "$@" --aspect "$aspect" --backend "$SOUL_NS_BACKEND" --render-scale "$SOUL_NS_RENDER_SCALE" ) &
fi
game_pid=$!
wait "$game_pid"
status=$?
game_pid=
exit "$status"
