#!/bin/bash
# INPUT:  launcher_platform.sh、端口/固件身份、真实显示 socket 与选定运行目录的私有库
# OUTPUT: launcher_compat_probe()、launcher_compat_plan()、launcher_compat_exec()、launcher_compat_describe()
# POS:    共享呈现路径选择与独立驱动计划，仅在目标子进程应用所选补丁
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech

# Function library: sourcing, matching and planning never start a game or
# modify the caller's graphics environment. Engine-owned native preflights
# remain mandatory; matching a profile is not evidence of working gameplay.
launcher_compat_accepts() {
  case "$1:$2" in
    unity-rudroid:gles|godot-sdl2:gles) return 0 ;;
    unity-rudroid:vulkan)
      # Title opt-in is separate from hardware capability. An unfamiliar board
      # with a working existing display may run the same native preflight.
      case "${PORT_NAME:-}" in
        silksong|vampiresurvivors114) return 0 ;;
        *) return 1 ;;
      esac ;;
    ns-vulkan:vulkan|ns-gles:gles) return 0 ;;
    unity-rudroid:malisx2)
      case "${PORT_NAME:-}:${CFW_NAME:-}" in
        silksong:Loong|vampiresurvivors114:Loong)
          launcher_platform_matches_compatible rockchip,rk3566-rk817-tablet ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# Check the optional Linux build without loading it. Android release packs use
# Bionic and cannot serve as a Linux ICD, even though both are AArch64 ELF.
launcher_compat_malisx2() {
  local helper="${2:-${PORTKIT_LAUNCHER_BIN_OVERRIDE:-${GAMEDIR:-}/bin/portkit-launcher}}"
  [ -x "$helper" ] || return 1
  "$helper" driver-check --directory "$1" --source-revision d0422ed5eb5d8971f118f14d2550ce04aa1a0a5a
}

launcher_compat_fail() {
  LAUNCHER_COMPAT_READY=0
  LAUNCHER_COMPAT_REASON="$1"
  printf '[compat] %s\n' "$1" >&2
  return 1
}

launcher_compat_wayland_socket() {
  local display="${WAYLAND_DISPLAY:-wayland-0}" dir candidate
  case "$display" in
    /*)
      if [ -S "$display" ]; then
        LAUNCHER_COMPAT_SOCKET="$display"
        return 0
      fi
      display=wayland-0 ;;
  esac
  for dir in "${XDG_RUNTIME_DIR:-}" /run "/run/user/$(id -u)" /var/run; do
    [ -n "$dir" ] || continue
    for candidate in "$display" wayland-0; do
      if [ -S "$dir/$candidate" ]; then
        LAUNCHER_COMPAT_SOCKET="$dir/$candidate"
        return 0
      fi
    done
  done
  return 1
}

launcher_compat_system_sdl() {
  local dir remaining="${LD_LIBRARY_PATH:-}:/usr/lib:/usr/lib64"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *:*) dir="${remaining%%:*}"; remaining="${remaining#*:}" ;;
      *) dir="$remaining"; remaining="" ;;
    esac
    [ -n "$dir" ] || continue
    if [ -r "$dir/libSDL2-2.0.so.0" ]; then
      printf '%s\n' "$dir/libSDL2-2.0.so.0"
      return 0
    fi
  done
  return 1
}

launcher_compat_sdl_has_driver() {
  # Match a whole NUL-terminated driver name. A substring like "mali" also
  # occurs in ordinary strings such as "normalization" in unrelated builds.
  LC_ALL=C tr '\000' '\n' < "$1" | LC_ALL=C grep -Fxi -- "$2" >/dev/null
}

# The SDL string scan preserves the existing port's selection heuristic. The
# selected SDL/runtime must still initialize successfully; this is not a GPU
# capability or firmware acceptance probe. Native Wayland always wins.
launcher_compat_godot_sdl() {
  local bundled="$1" system_sdl
  if launcher_compat_wayland_socket; then
    LAUNCHER_COMPAT_PROFILE=godot-sdl2-wayland
    LAUNCHER_COMPAT_SDL_DRIVER=wayland
    return 0
  fi
  LAUNCHER_COMPAT_ALSA=1
  case "${SDL_VIDEODRIVER:-}" in
    dummy) launcher_compat_fail 'Godot SDL2 requires a video driver with GL support, not dummy'; return 1 ;;
    ''|wayland) ;;
    *)
      LAUNCHER_COMPAT_PROFILE=godot-sdl2-firmware
      LAUNCHER_COMPAT_SDL_DRIVER="$SDL_VIDEODRIVER"
      return 0 ;;
  esac
  system_sdl="$(launcher_compat_system_sdl)" || system_sdl=""
  if [ -n "$system_sdl" ] && launcher_compat_sdl_has_driver "$system_sdl" mali; then
    LAUNCHER_COMPAT_PROFILE=godot-sdl2-mali
    LAUNCHER_COMPAT_SDL_DRIVER=mali
  elif [ -n "$bundled" ] && [ -r "$bundled/libSDL2-2.0.so.0" ] &&
       launcher_compat_sdl_has_driver "$bundled/libSDL2-2.0.so.0" kmsdrm; then
    LAUNCHER_COMPAT_PROFILE=godot-sdl2-bundled-kmsdrm
    LAUNCHER_COMPAT_SDL_DRIVER=kmsdrm
    LAUNCHER_COMPAT_LIBRARY_DIR="$bundled"
    LAUNCHER_COMPAT_PATCHES=bundled-sdl2
  else
    launcher_compat_fail 'Godot SDL2 has no selected GL video driver or usable bundled KMSDRM SDL2'
    return 1
  fi
}

# Interface: STACK BACKEND RUNTIME_DIR [BUNDLED_SDL_DIR] [PRESENTATION]. All outputs are owned
# LAUNCHER_COMPAT_* values. A failed/new selection invalidates the old plan.
# Keep concrete rules here; ports never assemble generic shell command strings.
launcher_compat_plan() {
  LAUNCHER_COMPAT_READY=0
  LAUNCHER_COMPAT_STACK="$1"
  LAUNCHER_COMPAT_BACKEND="$2"
  LAUNCHER_COMPAT_PROFILE=""
  LAUNCHER_COMPAT_PATCHES=""
  LAUNCHER_COMPAT_REASON=""
  LAUNCHER_COMPAT_LIBRARY_DIR=""
  LAUNCHER_COMPAT_WSI_DIR=""
  LAUNCHER_COMPAT_ICD_FILE=""
  LAUNCHER_COMPAT_SDL_DRIVER=""
  LAUNCHER_COMPAT_SOCKET=""
  LAUNCHER_COMPAT_ALSA=0
  LAUNCHER_COMPAT_PRESENTATION="${5:-wsi}"
  local runtime="$3" bundled="${4:-}"
  case "$runtime" in /*) ;; *) launcher_compat_fail 'runtime directory must be absolute'; return 1 ;; esac
  case "$runtime:$bundled" in
    *'
'*) launcher_compat_fail 'runtime/library paths must not contain newlines'; return 1 ;;
  esac
  case "$runtime" in *:*) launcher_compat_fail 'runtime directory must not contain a library-path separator'; return 1 ;; esac
  if [ -n "$bundled" ]; then
    case "$bundled" in /*) ;; *) launcher_compat_fail 'bundled SDL directory must be absolute'; return 1 ;; esac
    case "$bundled" in *:*) launcher_compat_fail 'bundled SDL directory must not contain a library-path separator'; return 1 ;; esac
  fi
  launcher_compat_accepts "$1" "$2" || {
    launcher_compat_fail "unsupported stack/backend or unaccepted title/device: $1/$2"
    return 1
  }
  case "$1:$2" in
    ns-gles:gles)
      [ "$LAUNCHER_COMPAT_PRESENTATION" = native ] || { launcher_compat_fail 'GLES requires its native display route'; return 1; }
      if launcher_compat_wayland_socket; then LAUNCHER_COMPAT_SDL_DRIVER=wayland
      elif [ -n "${DISPLAY:-}" ]; then LAUNCHER_COMPAT_SDL_DRIVER=x11
      else
        # Ownership/recovery is the prerequisite. The actual GLES probe, not
        # strings in one guessed SDL library, proves the selected driver works.
        if launcher_platform_can_acquire_display; then
          LAUNCHER_COMPAT_SDL_DRIVER=kmsdrm
        else launcher_compat_fail 'no validated native GLES display ownership path'; return 1
        fi
      fi
      LAUNCHER_COMPAT_PROFILE=ns-native-gles ;;
    unity-rudroid:gles) LAUNCHER_COMPAT_PROFILE=unity-system-gles ;;
    unity-rudroid:vulkan|unity-rudroid:malisx2|ns-vulkan:vulkan)
      case "$LAUNCHER_COMPAT_PRESENTATION" in native|wsi|portable) ;; *) launcher_compat_fail 'invalid presentation route'; return 1 ;; esac
      LAUNCHER_COMPAT_PROFILE="$1-${CFW_NAME:-generic}-$2-$LAUNCHER_COMPAT_PRESENTATION"
      local file
      if [ "$LAUNCHER_COMPAT_PRESENTATION" != native ]; then
        LAUNCHER_COMPAT_WSI_DIR="$runtime/vulkan-wsi"
        for file in libVkLayer_window_system_integration.so VkLayer_window_system_integration.json; do
          [ -s "$LAUNCHER_COMPAT_WSI_DIR/$file" ] || {
            launcher_compat_fail "missing private WSI file: $file"
            return 1
          }
        done
        LAUNCHER_COMPAT_PATCHES=private-wayland-wsi
      fi
      if [ "$LAUNCHER_COMPAT_PRESENTATION" = native ]; then
        if launcher_compat_wayland_socket; then LAUNCHER_COMPAT_SDL_DRIVER=wayland
        elif [ -n "${DISPLAY:-}" ]; then LAUNCHER_COMPAT_SDL_DRIVER=x11
        else launcher_compat_fail 'native presentation has no existing display'; return 1
        fi
      else
        LAUNCHER_COMPAT_SDL_DRIVER=wayland
        if [ "$LAUNCHER_COMPAT_PRESENTATION" = wsi ]; then launcher_compat_wayland_socket || true; fi
      fi
      if [ "$2" = malisx2 ]; then
        local driver="${LAUNCHER_MALISX2_DIR:-$runtime/vulkan-malisx2}"
        launcher_compat_malisx2 "$driver" "${PORTKIT_LAUNCHER_BIN_OVERRIDE:-$runtime/bin/portkit-launcher}" || {
          launcher_compat_fail 'missing or invalid malisx2 Linux driver'
          return 1
        }
        LAUNCHER_COMPAT_ICD_FILE="$driver/mali_icd.json"
        LAUNCHER_COMPAT_PATCHES="${LAUNCHER_COMPAT_PATCHES:+$LAUNCHER_COMPAT_PATCHES,}malisx2"
      fi ;;
    godot-sdl2:gles) launcher_compat_godot_sdl "$bundled" || return 1 ;;
  esac
  LAUNCHER_COMPAT_READY=1
}

launcher_compat_describe() {
  [ "${LAUNCHER_COMPAT_READY:-0}" = 1 ] || return 1
  printf '[compat] stack=%s backend=%s profile=%s patches=%s\n' \
    "$LAUNCHER_COMPAT_STACK" "$LAUNCHER_COMPAT_BACKEND" "$LAUNCHER_COMPAT_PROFILE" "${LAUNCHER_COMPAT_PATCHES:-none}"
  printf '[compat] sdl=%s library=%s wsi=%s\n' \
    "${LAUNCHER_COMPAT_SDL_DRIVER:-system}" "${LAUNCHER_COMPAT_LIBRARY_DIR:-system}" "${LAUNCHER_COMPAT_WSI_DIR:-system}"
}

# Engine adapters supply a trusted argv and an exact success marker. Selection
# never infers GPU support from board names or a library filename. A private
# compositor additionally requires an implemented frontend handoff/recovery.
launcher_compat_find_wayland() {
  local runtime="$1" helper image
  LAUNCHER_COMPAT_WAYLAND_HELPER=""
  LAUNCHER_COMPAT_WAYLAND_IMAGE=""
  [ -s "$runtime/portable-wayland/manifest.json" ] || return 1
  for image in "${LAUNCHER_WAYLAND_IMAGE:-}" "${controlfolder:-}/libs/weston_pkg_0.2.squashfs" "$runtime/weston_pkg_0.2.squashfs"; do
    [ -n "$image" ] && [ -s "$image" ] || continue
    for helper in "${LAUNCHER_WAYLAND_HELPER:-}" "${PORTKIT_LAUNCHER_BIN_OVERRIDE:-}" "${LAUNCHERDIR:-${GAMEDIR:-$runtime}}/bin/portkit-launcher" "$runtime/bin/portkit-launcher" "${GAMEDIR:-$runtime}/bin/portkit-launcher"; do
      [ -n "$helper" ] && [ -x "$helper" ] || continue
      if "$helper" wayland --runtime "$runtime" --weston-image "$image" --check >/dev/null 2>&1; then
        LAUNCHER_COMPAT_WAYLAND_HELPER="$helper"
        LAUNCHER_COMPAT_WAYLAND_IMAGE="$image"
        return 0
      fi
    done
  done
  return 1
}

launcher_compat_can_lease_display() {
  launcher_platform_can_acquire_display
}

launcher_compat_probe_marker() {
  case "
$1
" in *"
$2
"*) return 0 ;; *) return 1 ;; esac
}

# Interface: STACK DRIVER RUNTIME SUCCESS_MARKER PROBE_ARGV...
# Outputs a ready environment plan plus native/wsi/portable presentation. A
# selected driver is fixed for this call; presentation fallback never swaps ICD.
launcher_compat_probe() {
  LAUNCHER_COMPAT_READY=0
  LAUNCHER_COMPAT_PROBE_READY=0
  LAUNCHER_COMPAT_PROBE_REASON=""
  LAUNCHER_COMPAT_FALLBACK_REASON=""
  LAUNCHER_COMPAT_PRESENTATION=""
  LAUNCHER_COMPAT_DISPLAY_WIDTH=""
  LAUNCHER_COMPAT_DISPLAY_HEIGHT=""
  [ "$#" -ge 5 ] || { launcher_compat_fail 'graphics probe requires stack/driver/runtime/marker/argv'; return 1; }
  local stack="$1" backend="$2" runtime="$3" marker="$4" route output status video="" line
  local LAUNCHER_COMPAT_PROBING=1
  shift 4
  local helper="${PORTKIT_LAUNCHER_BIN_OVERRIDE:-${GAMEDIR:-}/bin/portkit-launcher}"
  if [ -x "$helper" ]; then
    set -- "$helper" bounded --seconds 8 -- "$@"
  elif command -v timeout >/dev/null 2>&1; then
    set -- timeout -k 1 8 "$@"
  else
    launcher_compat_fail 'a bounded engine graphics probe is required'; return 1
  fi
  if launcher_compat_wayland_socket; then video=wayland
  elif [ -n "${DISPLAY:-}" ]; then video=x11
  fi
  for route in native wsi portable; do
    if [ "$backend" = gles ] && [ "$route" != native ]; then continue; fi
    if [ "$route" = native ] && [ -z "$video" ] && [ "$stack:$backend" != ns-gles:gles ]; then
      LAUNCHER_COMPAT_PROBE_REASON='no existing native display or implemented direct presenter'
      continue
    fi
    if [ "$route" = wsi ] && [ "$video" != wayland ]; then continue; fi
    if [ "$route" = portable ]; then
      # Reuse an existing compositor; never stop it to probe another one.
      [ -z "$video" ] || continue
      if ! launcher_compat_can_lease_display; then
        LAUNCHER_COMPAT_PROBE_REASON='no supported display ownership/recovery adapter'
        continue
      fi
      if ! launcher_compat_find_wayland "$runtime"; then
        LAUNCHER_COMPAT_PROBE_REASON='private Wayland clients/compositor dependencies unavailable'
        continue
      fi
    fi
    if ! launcher_compat_plan "$stack" "$backend" "$runtime" "" "$route" >/dev/null 2>&1; then
      LAUNCHER_COMPAT_PROBE_REASON="$LAUNCHER_COMPAT_REASON"
      continue
    fi
    if [ "$route" = native ] && [ -n "$video" ]; then
      LAUNCHER_COMPAT_SDL_DRIVER="$video"
    elif [ "$route" != native ]; then
      LAUNCHER_COMPAT_SDL_DRIVER=wayland
    fi
    if [ "$video" = wayland ] && ! launcher_compat_wayland_socket; then
      # A disappearing compositor is not proof that DRM is free to acquire.
      # Invalidate the plan; the next launch can discover a fresh display.
      LAUNCHER_COMPAT_SOCKET=""
      LAUNCHER_COMPAT_PROBE_REASON='Wayland display disappeared before graphics probe'
      launcher_compat_fail "$LAUNCHER_COMPAT_PROBE_REASON"
      return 1
    fi
    status=0
    if [ "$route" = portable ] || [ "$LAUNCHER_COMPAT_SDL_DRIVER" = kmsdrm ]; then
      output="$( (
        # A settings UI can already hold the frontend lease in its parent.
        # A nested probe must not resume the parent restart loop on exit.
        if [ -z "${LAUNCHER_PLATFORM_RUNNERS:-}" ]; then
          trap launcher_platform_release_display EXIT
          launcher_platform_acquire_display || exit 1
        fi
        if [ "$route" = portable ]; then
          ( launcher_compat_exec "$LAUNCHER_COMPAT_WAYLAND_HELPER" wayland --runtime "$runtime" \
            --weston-image "$LAUNCHER_COMPAT_WAYLAND_IMAGE" \
            --log-dir "${LAUNCHER_COMPAT_LOG_DIR:-${GAMEDIR:-$runtime}/cache/wayland}" \
            -- "$@" )
        else
          ( launcher_compat_exec "$@" )
        fi
      ) 2>&1 )" || status=$?
    else
      output="$(launcher_compat_exec "$@" 2>&1)" || status=$?
    fi
    if [ "$status" = 0 ] && launcher_compat_probe_marker "$output" "$marker"; then
      while IFS= read -r line; do
        case "$line" in
          PORTKIT_DISPLAY_WIDTH=*) LAUNCHER_COMPAT_DISPLAY_WIDTH="${line#*=}" ;;
          PORTKIT_DISPLAY_HEIGHT=*) LAUNCHER_COMPAT_DISPLAY_HEIGHT="${line#*=}" ;;
        esac
      done <<EOF
$output
EOF
      case "$LAUNCHER_COMPAT_DISPLAY_WIDTH:$LAUNCHER_COMPAT_DISPLAY_HEIGHT" in
        *[!0-9:]*|:*|*:) LAUNCHER_COMPAT_DISPLAY_WIDTH=""; LAUNCHER_COMPAT_DISPLAY_HEIGHT="" ;;
      esac
      if [ "$LAUNCHER_COMPAT_DISPLAY_WIDTH" = 0 ] || [ "$LAUNCHER_COMPAT_DISPLAY_HEIGHT" = 0 ]; then
        LAUNCHER_COMPAT_DISPLAY_WIDTH=""; LAUNCHER_COMPAT_DISPLAY_HEIGHT=""
      fi
      LAUNCHER_COMPAT_FALLBACK_REASON="$LAUNCHER_COMPAT_PROBE_REASON"
      LAUNCHER_COMPAT_PROBE_REASON=""
      LAUNCHER_COMPAT_PROBE_READY=1
      printf '[compat] selected presentation=%s backend=%s\n' "$route" "$backend" >&2
      return 0
    fi
    LAUNCHER_COMPAT_PROBE_REASON="$route (exit $status): ${output:0:1024}"
  done
  launcher_compat_fail "${LAUNCHER_COMPAT_PROBE_REASON:-no usable graphics presentation path}"
}

# Call only in the game's existing subshell/background job or a disposable
# command substitution. Apply the plan, then replace that child through the
# platform's exec hook: no extra supervisor, PID change or parent env leakage.
# Arguments stay quoted positional values, never generated shell source.
launcher_compat_exec() {
  [ "${LAUNCHER_COMPAT_READY:-0}" = 1 ] && [ "$#" -gt 0 ] || return 1
  # Selection applies only in this disposable child. Reselecting system Vulkan
  # must also clear an ICD override inherited from a prior launch environment.
  unset VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES RUDROID_WSI_HEADLESS_SURFACE
  unset RUDROID_VULKAN_WSI_LIBRARY DM_WAYLAND_WSI_DIR DISABLE_WSI_LAYER
  if [ "${LAUNCHER_COMPAT_PRESENTATION:-}" = native ]; then
    unset VK_LAYER_PATH VK_INSTANCE_LAYERS
  fi
  if [ -n "$LAUNCHER_COMPAT_ICD_FILE" ]; then
    export VK_DRIVER_FILES="$LAUNCHER_COMPAT_ICD_FILE" VK_ICD_FILENAMES="$LAUNCHER_COMPAT_ICD_FILE"
    if [ -n "$LAUNCHER_COMPAT_WSI_DIR" ]; then export RUDROID_WSI_HEADLESS_SURFACE=1; fi
  fi
  if [ -n "$LAUNCHER_COMPAT_WSI_DIR" ]; then
    export DISABLE_WSI_LAYER=1
    export VK_LAYER_PATH="$LAUNCHER_COMPAT_WSI_DIR${VK_LAYER_PATH:+:$VK_LAYER_PATH}"
    export RUDROID_VULKAN_WSI_LIBRARY="$LAUNCHER_COMPAT_WSI_DIR/libVkLayer_window_system_integration.so"
  fi
  if [ -n "$LAUNCHER_COMPAT_LIBRARY_DIR" ]; then
    export LD_LIBRARY_PATH="$LAUNCHER_COMPAT_LIBRARY_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
  if [ -n "$LAUNCHER_COMPAT_SDL_DRIVER" ]; then
    export SDL_VIDEODRIVER="$LAUNCHER_COMPAT_SDL_DRIVER"
  fi
  if [ -n "$LAUNCHER_COMPAT_SOCKET" ]; then
    export XDG_RUNTIME_DIR="${LAUNCHER_COMPAT_SOCKET%/*}" WAYLAND_DISPLAY="${LAUNCHER_COMPAT_SOCKET##*/}"
    unset LIBGL_FB
  fi
  # audio_setup may have selected PulseAudio or an ALSA mixing route after
  # planning. Preserve that choice; ALSA is only the old no-compositor default.
  if [ "$LAUNCHER_COMPAT_ALSA" = 1 ] && [ -z "${SDL_AUDIODRIVER:-}" ]; then
    export SDL_AUDIODRIVER=alsa
  fi
  # Loong's legacy game-name workaround must not rename multicall utilities
  # such as timeout. NS already retains the visible frontend shell identity.
  if [ "${LAUNCHER_COMPAT_PROBING:-0}" = 1 ] || [ "$LAUNCHER_COMPAT_STACK" = ns-vulkan ] || [ "$LAUNCHER_COMPAT_STACK" = ns-gles ]; then
    exec "$@"
  else
    launcher_platform_exec "$@"
  fi
}
