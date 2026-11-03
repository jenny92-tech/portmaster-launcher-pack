#!/bin/bash
# INPUT:  已准备 NS 资源、私有执行目录、独立档案与 PortMaster 控制器库
# OUTPUT: 保留验收参数的游戏进程、事务式存档与退出恢复
# POS:    由 D2R NS 外层启动器调用的已验证 94012 游戏预设
# Some frontends explicitly invoke sh instead of respecting the shebang.
if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi
umask 077
d2r_package=$(CDPATH= cd -- "${1:?package directory}" && pwd -P)
d2r_installed=$(CDPATH= cd -- "${2:?installed runtime directory}" && pwd -P)
d2r_profile=${3:?profile directory}
d2r_controllers=${4:?controller database}
# Release 2026.10.26.1; verified ARM64 Linux build 94012.
unset DM_QUAD_CPU_READ_VERIFY DM_VK_QUAD_READ_CONTROL
export D2R_CLASSIC30=1
export D2R_REMASTER3D=0
export D2R_NATIVE_HD_MASK=7
export DM_LINUX_AOC_MANIFEST="$d2r_package/game/owned-content.txt"
export D2R_SHARED_POOL_MIN_MB=256
export D2R_SHADER_IMAGE="$d2r_package/game/classic-shaders/shaders.squashfs"
export D2R_SHADER_ROOT="$d2r_package/game/classic-shaders/root"
export D2R_PIPELINE_CACHE="$d2r_package/game/pipeline-cache/release-2026.10.26.1"
unset D2R_EXTRA_OVERLAY D2R_PREPARED_ROOT DM_LINUX_STATIC_MENU
export DM_LINUX_STATIC_MENU=1
export D2R_OVERLAY_ROOT="$d2r_package/game/Update/RomFS"
export D2R_3D_SCALE=1
export D2R_POOL_WINDOWS=1
export DM_LINUX_COMPACT_ARRAY_IMAGES=1
export DM_RENDER_SLOTS=2
export DM_TEMP_CACHE_IDLE_FRAMES=300
export DM_LINUX_COMPACT_2D_IMAGES=1
export D2R_SHARED_POOL_MIN_MB=192
export D2R_SHARED_POOL_MAX_MB=256
d2r_gov_paths=()
d2r_gov_values=()
d2r_control_dir=
d2r_game_pid=
runtime="$d2r_installed/runtime"
game="$d2r_package/game"
profile="$d2r_profile"
controllers="$d2r_controllers"
patches="$d2r_installed/native"
d2r_stage=diagnostics
mkdir -p "$game/diagnostics/launcher" || exit 1
d2r_launch_log=$(mktemp "$game/diagnostics/launcher/launch.XXXXXX") || exit 1
exec 4>&2
exec >>"$d2r_launch_log" 2>&1
d2r_finish() {
    d2r_status=$?
    set +e
    for d2r_i in "${!d2r_gov_paths[@]}"; do
        if printf '%s' "${d2r_gov_values[$d2r_i]}" >"${d2r_gov_paths[$d2r_i]}"; then
            printf 'D2R_GOVERNOR_RESTORED path=%s expected=%s actual=%s\n' \
                "${d2r_gov_paths[$d2r_i]}" "${d2r_gov_values[$d2r_i]}" "$(cat "${d2r_gov_paths[$d2r_i]}")"
        else
            printf 'D2R_GOVERNOR_RESTORE_FAILED path=%s\n' "${d2r_gov_paths[$d2r_i]}"
        fi
    done
    if [ -n "$d2r_control_dir" ]; then
        rm -f -- "$d2r_control_dir/performance"
        rmdir -- "$d2r_control_dir"
    fi
    printf 'D2R_LAUNCH_EXIT status=%s stage=%s\n' "$d2r_status" "$d2r_stage"
    if [ "$d2r_status" -ne 0 ]; then
        printf 'D2R launch failed (%s, %s). Log: %s\n' \
            "$d2r_status" "$d2r_stage" "$d2r_launch_log" >&4
    fi
}
trap d2r_finish EXIT
printf 'D2R_LAUNCH_START %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
set -eu
d2r_stage=runtime-files
d2r_prepared=${D2R_PREPARED_ROOT:-$game/handheld-prepared-128}
d2r_overlay=${D2R_OVERLAY_ROOT:-$game/astc-90447/RomFS}
if [ -f "$d2r_prepared/installed.json" ]; then
    test -f "$d2r_prepared/manifest.json"
    test -f "$d2r_prepared/shaders.squashfs"
    d2r_overlay="$d2r_prepared/RomFS"
    export DM_SHADER_ROOT="$d2r_prepared/shaders"
    export DM_SHADER_IMAGE="$d2r_prepared/shaders.squashfs"
    export DM_VK_PIPELINE_CACHE_DIR="$game/pipeline-cache"
fi
test -x "$runtime/d2r-linux-novideo"
test -f "$runtime/run-bringup.sh"
for d2r_module in main sdk subsdk0; do
    test -f "$patches/$d2r_module.patched.bin"
done
test -f "$game/Update/RomFS/data/build_manifest.psv"
test -d "$d2r_overlay"
test -f "$controllers"
d2r_stage=profile-directories
mkdir -p "$profile/save" "$profile/identity" "$game/diagnostics/interactive" \
    "$game/diagnostics/shader-misses" "$game/snapshot-cache-offline90447"
exec 9>"$profile/session.lock"
d2r_stage=session-lock
if ! flock -n 9; then
    printf 'Another D2R session holds the profile lock.\n'
    exit 0
fi
unset DM_KBD DM_TEST_SWKBD_LAG_MS
export D2R_SAVE_DIR="$profile/save" D2R_PROFILE_DIR="$profile/identity"
export D2R_PATCH_DIR="$patches"
export D2R_STATE_DIR="${D2R_STATE_DIR:-$game/diagnostics/interactive}"
export D2R_SKIP_MOVIES=1 D2R_CAPTURE_FRAMES=0
export DM_ROMFS_OVERLAY="$d2r_overlay"
if [ -n "${D2R_EXTRA_OVERLAY:-}" ]; then
    test -f "$D2R_EXTRA_OVERLAY/data/.build.config"
    export DM_ROMFS_OVERLAY="$D2R_EXTRA_OVERLAY:$DM_ROMFS_OVERLAY"
fi
# Installation derives the floor from the verified prepared pool capacities.
export DM_LINUX_SHARED_POOLS=1 DM_LINUX_SHARED_POOL_MIN_MB="${D2R_SHARED_POOL_MIN_MB:-384}"
export DM_LINUX_SNAPSHOT_CACHE="$game/snapshot-cache-offline90447"
export DM_LINUX_SHADER_FILE_BACKING=1 DM_LINUX_MALLOC_TRIM=1
# Full control/code comparisons retain shader identity on every cache hit.
export DM_SHADER_IDENTITY_CACHE=1
# Original-engine world scale; the 960x720 UI/output is kept at native size.
export DM_LINUX_3D_SCALE="${D2R_3D_SCALE:-1}"
export MALLOC_ARENA_MAX=2 MALLOC_TRIM_THRESHOLD_=131072
export DM_SHADER_MISS_ROOT="$game/diagnostics/shader-misses"
if [ -n "${D2R_SHADER_ROOT:-}" ]; then export DM_SHADER_ROOT="$D2R_SHADER_ROOT"; fi
if [ -n "${D2R_SHADER_IMAGE:-}" ]; then export DM_SHADER_IMAGE="$D2R_SHADER_IMAGE"; fi
if [ -n "${D2R_PIPELINE_CACHE:-}" ]; then export DM_VK_PIPELINE_CACHE_DIR="$D2R_PIPELINE_CACHE"; fi
# The renderer creates only the last directory component. Prepare configured
# parents here so a new preset can actually persist its validated driver cache.
if [ -n "${DM_VK_PIPELINE_CACHE_DIR:-}" ]; then
    d2r_stage=pipeline-cache-directory
    mkdir -p -- "$DM_VK_PIPELINE_CACHE_DIR"
fi
# Keep the handheld controller responsive across compositor focus changes.
export SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1
cd "$runtime"
if [ "${5:-}" = --check ]; then
    d2r_stage=preflight-complete
    printf 'D2R preflight passed; game was not started.\n'
    exit 0
fi
case "${D2R_CLASSIC30:-0}:${D2R_REMASTER3D:-0}" in
    0:0) ;;
    1:0|0:1)
    export DM_LINUX_SHARED_POOL_HEAP=system-uncached DM_LINUX_SHARED_ASYNC=1
    case "${D2R_SHARED_POOL_MAX_MB:-1024}" in
        256|384|512|1024) export DM_LINUX_SHARED_POOL_MAX_MB="${D2R_SHARED_POOL_MAX_MB:-1024}" ;;
        *) printf 'unsupported D2R_SHARED_POOL_MAX_MB\n'; exit 1 ;;
    esac
    export DM_LINUX_SNAPSHOT_RAM_MB=128
    export DM_LINUX_QUAD_BATCH=1 DM_LINUX_QUAD_BATCH_SPRITES=1
    export DM_LINUX_SHADER_CODE_LEASE=1 DM_LINUX_CONTROL_PAGE_WATCH=1
    export DM_LINUX_RECORD_STATE_CACHE=1
    unset DM_DISABLE_ASYNC_COMMIT DM_ASYNC_DRAIN DM_LINUX_LEGACY_GRAPHICS
    unset DM_PROFILE_DETAIL DM_PASS_TIMING DM_WORK_STATS DM_RESOURCE_STATS
    unset DM_TEXTURE_UPLOAD_PROFILE DM_LINUX_QUAD_KEY_VERIFY
    export DM_COUNTER_LIVENESS=1 DM_NVN_1D_AS_2D=1
    export DM_DRIVER_PUSH=1
    if [ "${D2R_CLASSIC30:-0}" = 1 ]; then
        # Requires prepare_classic_native.py format 6 and the matching runtime.
        export DM_LINUX_AUTO_CLASSIC=1 DM_LINUX_NATIVE_HD_MASK="${D2R_NATIVE_HD_MASK:-119}"
        export DM_LINUX_INDEXED_SPRITES=1
        export DM_CLASSIC_RENDER_CULL=1 DM_CLASSIC_PLAN_MEMO=1
        export DM_CLASSIC_HD_TERRAIN_FREEZE=1 DM_CLASSIC_ALLOW_HD_EFFECT_FREEZE=1
        export DM_CLASSIC_HD_EFFECT_FREEZE=1
        d2r_perf_flags=4292739279
    else
        unset DM_LINUX_AUTO_CLASSIC DM_LINUX_NATIVE_HD_MASK DM_LINUX_NATIVE_HD_CONTROL
        unset DM_LINUX_INDEXED_SPRITES DM_LINUX_INDEX_BATCH_CONTROL
        unset DM_CLASSIC_RENDER_CULL DM_CLASSIC_PLAN_MEMO DM_CLASSIC_HD_TERRAIN_FREEZE
        unset DM_CLASSIC_ALLOW_HD_EFFECT_FREEZE DM_CLASSIC_HD_EFFECT_FREEZE
        d2r_perf_flags=3745644751
    fi
    # Optional CPU-accessible pool residency, with fence-owned host uploads.
    case "${D2R_POOL_WINDOWS:-${DM_LINUX_POOL_WINDOWS:-0}}" in
        0) unset DM_LINUX_POOL_WINDOWS ;;
        1)
            export DM_LINUX_POOL_WINDOWS=1
            ;;
        *) printf 'D2R_POOL_WINDOWS requires 0 or 1\n'; exit 1 ;;
    esac
    # End optional pool residency.
    d2r_control_dir=$(mktemp -d /run/d2r-render.XXXXXX)
    export DM_LINUX_PERF_CONTROL="$d2r_control_dir/performance"
    printf '1 %s\n' "$d2r_perf_flags" >"$DM_LINUX_PERF_CONTROL"
    for d2r_path in /sys/devices/system/cpu/cpufreq/policy0/scaling_governor \
            /sys/class/devfreq/fde60000.gpu/governor /sys/class/devfreq/dmc/governor; do
        if [ -r "$d2r_path" ] && [ -w "$d2r_path" ]; then
            d2r_gov_paths+=("$d2r_path")
            d2r_gov_values+=("$(cat "$d2r_path")")
            printf performance >"$d2r_path"
            printf 'D2R_GOVERNOR_SELECTED path=%s previous=%s actual=%s\n' \
                "$d2r_path" "${d2r_gov_values[${#d2r_gov_values[@]}-1]}" "$(cat "$d2r_path")"
        fi
    done
    ;;
    *) printf 'Select only one of D2R_CLASSIC30=1 or D2R_REMASTER3D=1\n'; exit 1 ;;
esac
d2r_stop() {
    if [ -n "$d2r_game_pid" ]; then
        kill -TERM "$d2r_game_pid" 2>/dev/null || true
        wait "$d2r_game_pid" 2>/dev/null || true
    fi
}
trap d2r_stop INT TERM
d2r_stage=game
# Retain the wrapper to record errors that happen before the renderer's log.
unset DM_PRESENT_HZ DM_LINUX_WAIT_TRACE_FILE DM_PROFILE_DETAIL DM_PASS_TIMING DM_WORK_STATS
export DM_PRESENT_HZ=90
unset DM_ANDROID_PRESENT_60FPS
export DM_WAYLAND_WSI_DIR="$runtime/wayland-wsi"
export DM_LINUX_GPU_WRITE_WINDOWS=0
sh "$runtime/run-bringup.sh" "$game" graphics &
d2r_game_pid=$!
wait "$d2r_game_pid"
