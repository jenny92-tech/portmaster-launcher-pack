#!/bin/bash
# INPUT:  launcher_platform.sh、portmaster_common.sh、portkit-launcher、unityloader 与显示/按键设置
# OUTPUT: resolve_unity_runtime()、显示/内存/按键配置函数、run_unity_game()
# POS:    为 Unity 移植统一原子应用显示、渲染、内存和按键设置并编排运行
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech
#
# Unity-loader launcher helpers for Rudroid and legacy C++ ports.
# NOT for godot / other-engine ports.
# A pure FUNCTION LIBRARY: no top-level side effects. Depends on
# portmaster_common.sh (run_unity_game calls its audio/memory/sync/trap),
# so source portmaster_common.sh FIRST.
#
# Variables the functions read (set by the launcher preamble):
#   PORT_NAME, LOG_PREFIX, GAMEDIR, CONFDIR, DISPLAY_WIDTH, DISPLAY_HEIGHT
#
# Provides Unity-loader configuration helpers and run_unity_game.

# Separate executable host files from game resources on noexec media. An
# explicitly selected runtime wins; an installed Rudroid sidecar is otherwise
# preferred to legacy game-local executables. No resource or save path moves.
resolve_unity_runtime() {
  local candidate="${UNITY_RUNTIME_DIR:-}"
  if [ -z "$candidate" ]; then
    candidate="$GAMEDIR"
    if [ -n "${PORT_NAME:-}" ] && [ -d "/userdata/$PORT_NAME-runtime/rudroid.runtime" ]; then
      candidate="/userdata/$PORT_NAME-runtime"
    fi
  fi
  case "$candidate" in
    /*) ;;
    *) echo "$LOG_PREFIX runtime directory must be absolute: $candidate"; return 1 ;;
  esac
  if [ "$candidate" != "$GAMEDIR" ] &&
     { [ ! -x "$candidate/unityloader" ] || [ ! -d "$candidate/rudroid.runtime" ]; }; then
    echo "$LOG_PREFIX incomplete Rudroid runtime: $candidate"
    return 1
  fi
  UNITY_RUNTIME_DIR="$candidate"
  if [ -x "$candidate/bin/portkit-launcher" ]; then
    export PORTKIT_LAUNCHER_BIN_OVERRIDE="$candidate/bin/portkit-launcher"
  fi
  if [ -x "$candidate/gptokeyb" ]; then
    GPTOKEYB="$candidate/gptokeyb"
  fi
}

# ── The loader takes the toml path as argv[1] and never looks at the name, so
# one name across all ports lets the kit own the path. Sets PORT_TOML.
resolve_port_toml() {
  case "$GAMEDIR" in
    /*) ;;
    *) echo "$LOG_PREFIX game directory must be absolute: $GAMEDIR"; return 1 ;;
  esac
  PORT_TOML="$GAMEDIR/config.toml"
  [ -f "$PORT_TOML" ] && return 0
  echo "$LOG_PREFIX no config.toml in $GAMEDIR — the loader will fail to start"
  return 1
}

# ── Resolution. The toml's [device] size is per-device runtime state, NOT a
# shipped constant — whatever we commit is our own dev panel and is wrong for
# everyone else. PortMaster already probes the real panel every launch
# (device_info.txt: sdl_resolution -> DISPLAY_WIDTH/HEIGHT), so resolve on
# EVERY launch: an explicit launcher pick wins, otherwise follow the panel.
# Must run OUTSIDE the "launcher UI ran" branch — players whose CFW has no
# frt_3.x squashfs never get a launch_config.env, and used to be stuck with
# the baked-in size. Sets RES_W / RES_H. Args: $1=width $2=height, where
# ""/"auto"/garbage all mean "follow the panel". ─────────────────────────
resolve_display_resolution() {
  local want_w="$1" want_h="$2"
  RES_W=""; RES_H=""

  case "$want_w:$want_h" in
    auto:*|:*|*:) ;;
    *[!0-9]*:*|*:*[!0-9]*) echo "$LOG_PREFIX bad resolution '${want_w}x${want_h}' — following the panel" ;;
    *) RES_W="$want_w"; RES_H="$want_h" ;;
  esac

  if [ -n "$RES_W" ]; then
    echo "$LOG_PREFIX resolution ${RES_W}x${RES_H} (launcher choice)"
  else
    RES_W="$DISPLAY_WIDTH"; RES_H="$DISPLAY_HEIGHT"
    echo "$LOG_PREFIX resolution ${RES_W}x${RES_H} (panel, auto-detected)"
  fi

  # PortMaster itself falls back to 640x480 when sdl_resolution fails; if even
  # that is missing (unknown CFW), don't write garbage into the toml.
  case "$RES_W:$RES_H" in
    *[!0-9]*:*|*:*[!0-9]*|:*|*:)
      RES_W=640; RES_H=480
      echo "$LOG_PREFIX no panel size from PortMaster — 640x480" ;;
  esac
}

# Commit output size, optional scale and optional Rudroid memory mode together.
# "config" keeps the exact/percentage render preset and the existing filter.
# Reported sizes describe the config; the fullscreen SDL drawable can differ.
# Keep dimensions available for game-specific settings (e.g. Hollow Knight).
configure_unity_display() {
  local toml="$1" render="${4:-config}" memory="${5:-}" graphics="${6:-}" filter="${7:-config}" report extra dimension feature
  case "$render" in config|100|75|50) : ;; *) echo "$LOG_PREFIX invalid render selection: $render"; return 1 ;; esac
  case "$filter" in config|sharp|linear) : ;; *) echo "$LOG_PREFIX invalid scale filter: $filter"; return 1 ;; esac
  if [ "$graphics" = vulkan ]; then
    prepare_unity_vulkan_environment || return 1
    filter=linear
  fi
  feature=gles-scale; [ "$graphics" != vulkan ] || feature=vulkan-scale
  case ",${PORTKIT_GRAPHICS_FEATURES:-sdl2,gles,gles-scale,gles-sharp}," in
    *,$feature,*) : ;;
    *) render=100; filter=config; echo "$LOG_PREFIX render scaling unavailable; using Native (100%)" ;;
  esac
  if [ "$graphics" != vulkan ]; then
    if [ "$render" = 100 ]; then filter=config
    else
      case ",${PORTKIT_GRAPHICS_FEATURES:-sdl2,gles,gles-scale,gles-sharp}," in
        *,gles-sharp,*) : ;; *) filter=linear ;;
      esac
    fi
  fi
  resolve_display_resolution "${2:-auto}" "${3:-auto}"
  set -- unity configure --file "$toml" --section device \
    --width "$RES_W" --height "$RES_H" --print-dimensions true
  case "$render" in
    config) RENDER_SCALE_PERCENT=config ;;
    100|75|50) RENDER_SCALE_PERCENT="$render"; set -- "$@" --render-percent "$render" ;;
    *) echo "$LOG_PREFIX invalid render selection: $render"; return 1 ;;
  esac
  [ -z "$memory" ] || set -- "$@" --memory-mode "$memory"
  [ -z "$graphics" ] || set -- "$@" --graphics-api "$graphics"
  set -- "$@" --render-filter "$filter"
  if report="$(portkit_launcher "$@")"; then :; else return $?; fi
  case "$report" in
    *[!0-9\ ]*) echo "$LOG_PREFIX invalid Unity dimensions report"; return 1 ;;
  esac
  read -r RES_W RES_H RENDER_W RENDER_H extra <<EOF
$report
EOF
  [ -z "$extra" ] || { echo "$LOG_PREFIX extra Unity dimensions"; return 1; }
  for dimension in "$RES_W" "$RES_H" "$RENDER_W" "$RENDER_H"; do
    case "$dimension" in
      ""|0*) echo "$LOG_PREFIX invalid Unity dimensions report"; return 1 ;;
    esac
  done
  echo "$LOG_PREFIX configured output=${RES_W}x${RES_H} render=${RENDER_W}x${RENDER_H} selection=$RENDER_SCALE_PERCENT memory=${memory:-config}"
}

# Query compiled runtime support once, before UI startup. Title acceptance and
# a live platform session remain independent. Accepted Vulkan titles perform a
# bounded disposable native preflight once; no guest or game frame is started.
prepare_unity_graphics_options() {
  local runtime="${UNITY_RUNTIME_DIR:-$GAMEDIR}" wsi features wayland_socket probe
  [ "${UNITY_GRAPHICS_PROBED_RUNTIME:-}" != "$runtime" ] || return 0
  wsi="$runtime/vulkan-wsi"
  PORTKIT_GRAPHICS_FEATURES=sdl2,gles,gles-scale,gles-sharp
  PORTKIT_GRAPHICS_QUERY=legacy
  if [ -d "$runtime/rudroid.runtime" ] && [ -x "$runtime/unityloader" ]; then
    if features="$("$runtime/unityloader" "$runtime/rudroid.runtime" --graphics-features 2>/dev/null)"; then
      case "$features" in
        *[!a-z0-9,-]*) PORTKIT_GRAPHICS_FEATURES= ;;
        *) PORTKIT_GRAPHICS_FEATURES="$features" ;;
      esac
      PORTKIT_GRAPHICS_QUERY=reported
    fi
  fi
  PORTKIT_VULKAN_AVAILABLE=0
  PORTKIT_VULKAN_PLATFORM_SUPPORTED=0
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
      /*) wayland_socket="$WAYLAND_DISPLAY" ;;
      *) wayland_socket="${XDG_RUNTIME_DIR:-/run}/$WAYLAND_DISPLAY" ;;
    esac
    [ ! -S "$wayland_socket" ] || PORTKIT_VULKAN_PLATFORM_SUPPORTED=1
  fi
  case ",$PORTKIT_GRAPHICS_FEATURES," in *,vulkan,*)
    if [ "${1:-0}" = 1 ] && [ "$PORTKIT_VULKAN_PLATFORM_SUPPORTED" = 1 ] &&
       [ -s "$wsi/libVkLayer_window_system_integration.so" ] &&
       [ -s "$wsi/VkLayer_window_system_integration.json" ] && command -v timeout >/dev/null 2>&1; then
      if probe="$(DISABLE_WSI_LAYER=1 VK_LAYER_PATH="$wsi${VK_LAYER_PATH:+:$VK_LAYER_PATH}" \
        RUDROID_VULKAN_WSI_LIBRARY="$wsi/libVkLayer_window_system_integration.so" \
        timeout -k 1 8 "$runtime/unityloader" "$runtime/rudroid.runtime" --probe-vulkan 2>&1)"; then
        case "
$probe
" in *'
RUDROID_VULKAN=1
'*) PORTKIT_VULKAN_AVAILABLE=1 ;; esac
      else
        printf '%s Vulkan preflight failed: %.1024s\n' "$LOG_PREFIX" "$probe"
      fi
    fi ;;
  esac
  case ",$PORTKIT_GRAPHICS_FEATURES," in *,vulkan-linear,*) : ;; *) PORTKIT_VULKAN_AVAILABLE=0 ;; esac
  UNITY_GRAPHICS_PROBED_RUNTIME="$runtime"
  export PORTKIT_GRAPHICS_FEATURES PORTKIT_GRAPHICS_QUERY PORTKIT_VULKAN_AVAILABLE PORTKIT_VULKAN_PLATFORM_SUPPORTED
}

prepare_unity_vulkan_environment() {
  local wsi="${UNITY_RUNTIME_DIR:-$GAMEDIR}/vulkan-wsi"
  prepare_unity_graphics_options
  [ "$PORTKIT_VULKAN_AVAILABLE" = 1 ] || {
    echo "$LOG_PREFIX complete Vulkan runtime/feature report is missing; choose OpenGL ES"
    return 1
  }
  [ "$PORTKIT_VULKAN_PLATFORM_SUPPORTED" = 1 ] || {
    echo "$LOG_PREFIX Vulkan requires a live Wayland display session"
    return 1
  }
  # Process-local private WSI; never replace an ICD or a system driver.
  export DISABLE_WSI_LAYER=1
  export VK_LAYER_PATH="$wsi${VK_LAYER_PATH:+:$VK_LAYER_PATH}"
  export RUDROID_VULKAN_WSI_LIBRARY="$wsi/libVkLayer_window_system_integration.so"
}

resolve_unity_graphics_api() {
  local requested="${1:-gles}"
  prepare_unity_graphics_options "${3:-0}"
  case "$requested" in
    gles) UNITY_GRAPHICS_API="${2:-gles30}" ;;
    vulkan)
      if [ "${3:-0}" = 1 ] && [ "$PORTKIT_VULKAN_AVAILABLE" = 1 ] && [ "$PORTKIT_VULKAN_PLATFORM_SUPPORTED" = 1 ]; then
        UNITY_GRAPHICS_API=vulkan
      else
        echo "$LOG_PREFIX selected Vulkan backend is disabled for this title/environment"
        return 1
      fi ;;
    *) echo "$LOG_PREFIX invalid graphics backend: $1"; return 1 ;;
  esac
  if [ "$UNITY_GRAPHICS_API" != vulkan ]; then
    case ",$PORTKIT_GRAPHICS_FEATURES," in *,gles,*) : ;; *) echo "$LOG_PREFIX no available graphics backend"; return 1 ;; esac
  fi
  echo "$LOG_PREFIX selected graphics backend=$UNITY_GRAPHICS_API"
}

# ── [input.remap] upsert a/b/x/y without depending on device awk/sed.
# Args: $1=toml file, $2=a $3=b $4=x $5=y values. ───────────────────────
apply_button_remap() {
  local toml="$1" a="$2" b="$3" x="$4" y="$5"
  portkit_launcher unity configure \
    --file "$toml" --section input.remap --a "$a" --b "$b" --x "$x" --y "$y"
}

# ── Stage-2: run a unityloader game with all the handheld defenses. Identical
# across every Unity-loader port. Arg: $1 = toml passed to the loader. Pulls in
# audio_setup + memory_tuning + install_exit_trap from portmaster_common.sh,
# keeps normal OOM selection, then waits & finishes.
# Keep a supplied private C++ bundle ahead of game and firmware libraries.
# The legacy C++ loader requires it; Rudroid kits do not require a C++ launcher ABI.
prepare_unityloader_private_libs() {
  local runtime="${UNITY_RUNTIME_DIR:-$GAMEDIR}"
  local private_libs="$runtime/unityloader.libs"
  local library
  if [ -d "$runtime/rudroid.runtime" ]; then
    # The Rust kit has no mandatory private C++ launcher runtime. Retain a
    # supplied bundle in its existing search position, without requiring it.
    [ ! -d "$private_libs" ] || export LD_LIBRARY_PATH="$private_libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    return 0
  fi
  for library in libstdc++.so.6 libgcc_s.so.1; do
    [ -r "$private_libs/$library" ] || {
      echo "$LOG_PREFIX missing unityloader private library: $private_libs/$library"
      return 1
    }
  done
  export LD_LIBRARY_PATH="$private_libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

run_unity_game() {
  local toml="$1" game_library_paths="${2:-}" unity_status
  local game_input_pid=""
  resolve_unity_runtime || return 1
  # get_controls populates sdl_controllerconfig, but the settings UI runs in
  # a subshell so its SDL_GAMECONTROLLERCONFIG export cannot reach the game.
  # Re-export the PortMaster mapping for Unity's own SDL input backend.
  if [ -n "${sdl_controllerconfig:-}" ]; then
    export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
  fi
  if [ -n "$game_library_paths" ]; then
    export LD_LIBRARY_PATH="$game_library_paths${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
  prepare_unityloader_private_libs || return 1
  export XDG_DATA_HOME="$CONFDIR"
  export XDG_CONFIG_HOME="$CONFDIR"
  mkdir -p "$GAMEDIR/cache/UnityShaderCache"

  audio_setup
  memory_tuning
  install_exit_trap

  chmod a+x "$UNITY_RUNTIME_DIR/unityloader" || return 1
  launcher_platform_prepare_game "$UNITY_RUNTIME_DIR/unityloader"

  if [ -n "${UNITY_GAME_GPTK_CONFIG:-}" ]; then
    # PortMaster's GPTOKEYB is a trusted command prefix (it can include sudo
    # and preload arguments), not a single executable path.
    if [ -z "${GPTOKEYB:-}" ] || [ ! -r "$UNITY_GAME_GPTK_CONFIG" ]; then
      echo "$LOG_PREFIX missing Unity game input bridge: $UNITY_GAME_GPTK_CONFIG"
      return 1
    fi
  fi

  "$UNITY_RUNTIME_DIR/unityloader" "$toml" &
  local unity_pid=$!
  if [ -n "${UNITY_GAME_GPTK_CONFIG:-}" ]; then
    $GPTOKEYB unityloader -c "$UNITY_GAME_GPTK_CONFIG" &
    game_input_pid=$!
    echo "$LOG_PREFIX Unity game input bridge pid=$game_input_pid"
  fi
  # Keep normal OOM selection so a large guest can be reclaimed under pressure.
  echo 0 > "/proc/$unity_pid/oom_score_adj" 2>/dev/null

  wait "$unity_pid"
  unity_status=$?
  if [ -n "$game_input_pid" ]; then
    kill "$game_input_pid" 2>/dev/null
    wait "$game_input_pid" 2>/dev/null
  fi
  launcher_platform_finish
  return "$unity_status"
}
