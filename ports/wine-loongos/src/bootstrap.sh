#!/bin/sh
# INPUT:  ARM64 Linux、随包只读 SquashFS、mount/sha256sum 与应用目录
# OUTPUT: WINE_RUNNER_PYTHON/WINE_RUNNER_BOOTSTRAP 私有执行环境
# POS:    在没有系统 Python 和 PortMaster 时加载启动器自己的依赖

wine_bootstrap() {
    [ "$(uname -m)" = aarch64 ] || { echo 'Wine launcher bootstrap requires ARM64 Linux.' >&2; return 78; }
    wine_bootstrap_app=$(CDPATH= cd -- "$1" && pwd)
    wine_bootstrap_source="$wine_bootstrap_app/bootstrap-aarch64.squashfs"
    wine_bootstrap_hash=$(cat "$wine_bootstrap_app/bootstrap.sha256")
    case "$wine_bootstrap_hash" in *[!0123456789abcdef]*|'') echo 'Invalid launcher bootstrap checksum.' >&2; return 78 ;; esac
    [ "${#wine_bootstrap_hash}" = 64 ] || return 78
    [ -f "$wine_bootstrap_source" ] && [ ! -L "$wine_bootstrap_source" ] || { echo 'Missing private launcher environment.' >&2; return 78; }
    # Never mount the delivery file in place: an application update may rewrite it.
    # A content-addressed private copy keeps an active interpreter image immutable.
    wine_bootstrap_cache=${WINE_RUNNER_BOOTSTRAP_CACHE:-$wine_bootstrap_app/.bootstrap-cache}
    [ ! -L "$wine_bootstrap_cache" ] || return 78
    mkdir -p "$wine_bootstrap_cache"
    wine_bootstrap_cache=$(CDPATH= cd -- "$wine_bootstrap_cache" && pwd)
    wine_bootstrap_image="$wine_bootstrap_cache/$wine_bootstrap_hash.squashfs"
    [ ! -L "$wine_bootstrap_image" ] || return 78
    if [ ! -f "$wine_bootstrap_image" ]; then
        wine_bootstrap_temporary="$wine_bootstrap_cache/$wine_bootstrap_hash.$$.preparing"
        cp "$wine_bootstrap_source" "$wine_bootstrap_temporary" || return 78
        wine_bootstrap_actual=$(sha256sum "$wine_bootstrap_temporary") || return 78
        if [ "${wine_bootstrap_actual%% *}" != "$wine_bootstrap_hash" ]; then
            rm -f "$wine_bootstrap_temporary"
            echo 'Private launcher environment is damaged.' >&2; return 78
        fi
        # rename preserves any already-open inode if two first launches overlap.
        mv "$wine_bootstrap_temporary" "$wine_bootstrap_image"
    fi
    wine_bootstrap_target="/tmp/wine-bootstrap-$(printf '%s' "$wine_bootstrap_hash" | cut -c1-16)"
    [ ! -L "$wine_bootstrap_target" ] || return 78
    mkdir -p "$wine_bootstrap_target"
    wine_bootstrap_device=''
    while read -r wine_mount_id wine_parent_id wine_mount_device wine_mount_root wine_mount_path wine_mount_rest; do
        if [ "$wine_mount_path" = "$wine_bootstrap_target" ]; then wine_bootstrap_device=$wine_mount_device; break; fi
    done < /proc/self/mountinfo
    if [ -n "$wine_bootstrap_device" ]; then
        case "$wine_bootstrap_device" in *[!0123456789:]*|'') return 78 ;; esac
        wine_bootstrap_backing=$(cat "/sys/dev/block/$wine_bootstrap_device/loop/backing_file") || return 78
        wine_bootstrap_backing=$(printf '%b' "$wine_bootstrap_backing")
        [ "/${wine_bootstrap_backing#/}" = "$wine_bootstrap_image" ] || { echo 'Private launcher mount belongs to another image.' >&2; return 78; }
    else
        wine_bootstrap_actual=$(sha256sum "$wine_bootstrap_image") || return 78
        [ "${wine_bootstrap_actual%% *}" = "$wine_bootstrap_hash" ] || { echo 'Private launcher environment is damaged.' >&2; return 78; }
        mount -t squashfs -o loop,ro,nodev,nosuid,exec "$wine_bootstrap_image" "$wine_bootstrap_target" || return 78
    fi
    WINE_RUNNER_BOOTSTRAP=$wine_bootstrap_target
    WINE_RUNNER_PYTHON="$wine_bootstrap_target/python/bin/python3"
    [ -x "$WINE_RUNNER_PYTHON" ] || { echo 'Private Python is missing.' >&2; return 78; }
    export WINE_RUNNER_BOOTSTRAP WINE_RUNNER_PYTHON
}
