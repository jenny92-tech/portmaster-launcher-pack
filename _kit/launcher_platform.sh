#!/bin/bash
# INPUT:  系统显示环境、device-tree、Wayland、PortMaster hooks、输入服务与 awk/FIFO 有界日志工具
# OUTPUT: launcher_platform_* 显示/尺寸、异常日志、游戏生命周期与旧固件兼容入口
# POS:    随启动包内联的系统适配层，不依赖定制 PortMaster 版本

# Keep third-party UI startup output off the card in normal sessions. Only
# failures, structured runtime errors or explicit diagnostics retain context.
launcher_platform_start_log() {
  LAUNCHER_LOG_TARGET="$1"
  if [ "${RUDROID_DIAGNOSTICS:-0}" = 1 ] || [ "${BOGODROID_DIAGNOSTICS:-0}" = 1 ]; then
    exec > "$LAUNCHER_LOG_TARGET" 2>&1
    return 0
  fi
  LAUNCHER_LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/portkit-log.XXXXXX") || return 1
  mkfifo "$LAUNCHER_LOG_DIR/stream" || { rmdir "$LAUNCHER_LOG_DIR"; return 1; }
  LAUNCHER_LOG_END="__PORTKIT_END_${LAUNCHER_LOG_DIR##*/}__:"
  LC_ALL=C awk -v output="$LAUNCHER_LOG_TARGET" -v kept="$LAUNCHER_LOG_DIR/retained" \
    -v end_marker="$LAUNCHER_LOG_END" '
    BEGIN { status=1 }
    substr($0,1,length(end_marker))==end_marker {
      value=substr($0,length(end_marker)+1)
      if (value ~ /^[0-9]+$/) { status=value+0; exit }
    }
    {
      if (NR==1) header=substr($0,1,511) "\n"
      if ($0 ~ /^\[(ERROR|FATAL)\]/ && !failure) { failure=1; first_error=substr($0,1,4095) "\n" }
      buffer=buffer $0 "\n"
      if (length(buffer)>60300) buffer=substr(buffer,length(buffer)-60300+1)
    }
    END {
      if (status || failure) {
        printf "%s%s%s",header,first_error,buffer > output
        print "1" > kept
      } else printf "%s","" > output
      close(output)
    }
  ' "$LAUNCHER_LOG_DIR/stream" &
  LAUNCHER_LOG_PID=$!
  exec > "$LAUNCHER_LOG_DIR/stream" 2>&1
  trap 'launcher_platform_finish_log "$?"' EXIT
}

launcher_platform_log_needed() {
  [ "${1:-0}" != 0 ] || [ "${LAUNCHER_LOG_RETAINED:-0}" = 1 ] ||
    [ "${RUDROID_DIAGNOSTICS:-0}" = 1 ] || [ "${BOGODROID_DIAGNOSTICS:-0}" = 1 ]
}

launcher_platform_finish_log() {
  [ -n "${LAUNCHER_LOG_DIR:-}" ] || return 0
  printf '\n%s%s\n' "$LAUNCHER_LOG_END" "${1:-0}"
  exec > /dev/null 2>&1
  LAUNCHER_LOG_RETAINED=0
  wait "$LAUNCHER_LOG_PID" || LAUNCHER_LOG_RETAINED=1
  [ ! -f "$LAUNCHER_LOG_DIR/retained" ] || LAUNCHER_LOG_RETAINED=1
  rm -f -- "$LAUNCHER_LOG_DIR/stream" "$LAUNCHER_LOG_DIR/retained"
  rmdir "$LAUNCHER_LOG_DIR"
  unset LAUNCHER_LOG_DIR LAUNCHER_LOG_PID
}

# Prefer a live compositor over a firmware-name guess. In particular, /run
# must replace an inherited stale runtime dir when that is where the socket is.
# This selects a backend; Weston, not the game, owns its output rotation.
launcher_platform_display() {
  local display="${WAYLAND_DISPLAY:-wayland-0}" dir candidate
  case "$display" in
    /*)
      if [ -S "$display" ]; then
        export SDL_VIDEODRIVER=wayland
        unset LIBGL_FB
        return 0
      fi
      display=wayland-0
      ;;
  esac
  for dir in "${XDG_RUNTIME_DIR:-}" /run "/run/user/$(id -u)" /var/run; do
    [ -n "$dir" ] || continue
    for candidate in "$display" wayland-0; do
      if [ -S "$dir/$candidate" ]; then
        export XDG_RUNTIME_DIR="$dir" WAYLAND_DISPLAY="$candidate" SDL_VIDEODRIVER=wayland
        unset LIBGL_FB
        return 0
      fi
    done
  done
  # Do not overwrite a firmware-provided KMS, Mali or X11 backend. Only
  # discard a dead Wayland selection; SDL can then choose its native backend.
  if [ "${SDL_VIDEODRIVER:-}" = wayland ]; then unset SDL_VIDEODRIVER; fi
  unset WAYLAND_DISPLAY
  return 1
}

launcher_platform_resolution() {
  local width="${DISPLAY_WIDTH:-}" height="${DISPLAY_HEIGHT:-}" size
  case "$width:$height" in
    *[!0-9:]*|:*|*:) ;;
    *) if [ "$width" -gt 0 ] && [ "$height" -gt 0 ]; then return 0; fi ;;
  esac
  size=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) || size=""
  case "$size" in
    *,*) width="${size%,*}"; height="${size#*,}" ;;
    *) width=0; height=0 ;;
  esac
  case "$width:$height" in
    *[!0-9:]*|:*|*:) width=0; height=0 ;;
  esac
  if [ "$width" -le 0 ] || [ "$height" -le 0 ]; then
    width="${1:-640}"; height="${2:-480}"
  elif [ "${CFW_NAME:-}" = Loong ] && [ "${SDL_VIDEODRIVER:-}" = wayland ] &&
       [ "$height" -gt "$width" ]; then
    # Only this known firmware's raw fb fallback needs a landscape size.
    # Never transpose an arbitrary Wayland output or an already supplied size.
    size="$width"; width="$height"; height="$size"
  fi
  export DISPLAY_WIDTH="$width" DISPLAY_HEIGHT="$height"
}

# Exact device-tree entries, never a firmware-name or partial-model guess.
launcher_platform_matches_compatible() {
  local compatible_file="${2:-/proc/device-tree/compatible}"
  [ -r "$compatible_file" ] || return 1
  LC_ALL=C tr '\000' '\n' < "$compatible_file" | LC_ALL=C grep -Fxq -- "$1"
}

launcher_platform_resume_input() {
  # Legacy PortMaster helpers can leave these firmware input daemons stopped.
  # Keep that workaround here, not in Unity or an individual game. Running
  # daemons are untouched; no locks are deleted and no service is restarted.
  local proc executable state
  for proc in /proc/[0-9]*; do
    executable=$(readlink "$proc/exe" 2>/dev/null) || continue
    case "${executable##*/}" in input-event-daemon|loong_input) ;; *) continue ;; esac
    state=$(awk '/^State:/ { print $2 }' "$proc/status" 2>/dev/null)
    [ "$state" = T ] || continue
    kill -CONT "${proc##*/}" 2>/dev/null || true
  done
}

launcher_platform_prepare_game() {
  launcher_platform_display || true
  pm_platform_helper "$@"
  launcher_platform_resume_input
}

# Keep the existing Loong Godot launch identity in the compatibility layer.
# Use in the game's subshell so exec never replaces the cleanup owner.
launcher_platform_exec() {
  if [ "${CFW_NAME:-}" = Loong ]; then
    exec -a unityloader "$@"
  else
    exec "$@"
  fi
}

launcher_platform_finish() {
  launcher_platform_resume_input
  launcher_platform_release_display
  pm_finish
}

# An explicit port request for exclusive DRM access. Compositor sessions do
# not need this. Track only the runner stopped by this launch for restoration.
launcher_platform_acquire_display() {
  local runner main
  launcher_platform_display && return 0
  main=$(pidof MainUI 2>/dev/null) || return 0
  for runner in $(pidof runtrimui.sh 2>/dev/null); do
    case "$runner" in ''|*[!0-9]*) continue ;; esac
    if kill -STOP "$runner" 2>/dev/null; then
      LAUNCHER_PLATFORM_RUNNERS="${LAUNCHER_PLATFORM_RUNNERS:-} $runner"
    fi
  done
  for main in $main; do
    case "$main" in ''|*[!0-9]*) continue ;; esac
    kill -KILL "$main" 2>/dev/null || true
  done
  sleep 1
}

launcher_platform_release_display() {
  local runner
  for runner in ${LAUNCHER_PLATFORM_RUNNERS:-}; do
    kill -CONT "$runner" 2>/dev/null || true
  done
  LAUNCHER_PLATFORM_RUNNERS=""
}
