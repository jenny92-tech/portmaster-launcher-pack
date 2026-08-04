#!/bin/bash
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech
#
# Unity-loader launcher helpers — shared ONLY by ports that run the Bogodroid
# unityloader (e.g. hk, heishenhua). NOT for godot / other-engine ports.
# A pure FUNCTION LIBRARY: no top-level side effects. Depends on
# portmaster_common.sh (run_unity_game calls its audio/memory/sync/trap),
# so source portmaster_common.sh FIRST.
#
# Variables the functions read (set by the launcher preamble):
#   PORT_NAME, LOG_PREFIX, GAMEDIR, CONFDIR, DISPLAY_WIDTH, DISPLAY_HEIGHT
#
# Provides Unity-loader configuration helpers and run_unity_game.

# ── The loader takes the toml path as argv[1] and never looks at the name, so
# one name across all ports lets the kit own the path. Sets PORT_TOML.
resolve_port_toml() {
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

# Write the resolved size into the loader's toml. Arg: $1 = toml file.
# --section device: the loader reads config["device"]["displayWidth"] and falls
# back to 640x480 if it is missing. The table is named here, not baked into the
# helper, which only knows "set these keys in this table".
apply_display_resolution() {
  local toml="$1"
  portkit_launcher unity configure \
    --file "$toml" --section device --width "$RES_W" --height "$RES_H"
}

# Resolve the Unity render size independently from the physical output.
# Requires resolve_display_resolution first. Sets RENDER_SCALE_PERCENT and
# RENDER_W / RENDER_H. Args: $1=100|75|50. Invalid/missing values use native.
resolve_render_scale() {
  local want="${1:-100}"
  case "$want" in
    100|75|50) RENDER_SCALE_PERCENT="$want" ;;
    *)
      RENDER_SCALE_PERCENT=100
      echo "$LOG_PREFIX bad render percent '$want' — using native resolution"
      ;;
  esac
  RENDER_W=$((RES_W * RENDER_SCALE_PERCENT / 100))
  RENDER_H=$((RES_H * RENDER_SCALE_PERCENT / 100))
  echo "$LOG_PREFIX output=${RES_W}x${RES_H} render=${RENDER_W}x${RENDER_H} scale=${RENDER_SCALE_PERCENT}% filter=sharp"
}

# Write the render percentage into [gpu]. The helper also clears an old exact
# renderWidth/renderHeight pair, because exact dimensions override percentage.
apply_render_scale() {
  local toml="$1"
  portkit_launcher unity configure \
    --file "$toml" --render-percent "$RENDER_SCALE_PERCENT"
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
# lowers the loader's OOM score (raises audio daemons'), then waits & finishes.
restore_unity_handheld_input() {
  # Loong input can be left stopped if a previous experimental launcher or the
  # loader's Start+Select fast-exit path bypasses normal teardown. (/tmp/lock_loong_*
  # is each daemon's own singleton guard, not an input lock — deleting one only
  # broke loong_daemon's guard, so that is gone.)
  local p pid exe cmd
  for p in /proc/[0-9]*; do
    pid="${p##*/}"
    [ "$pid" = "$$" ] && continue
    exe=$(readlink "$p/exe" 2>/dev/null || true)
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)
    case "$exe:$cmd" in
      */input-event-daemon:*|*:/usr/bin/input-event-daemon*|*/loong_input:*|*:/loong/loong_input*)
        kill -CONT "$pid" 2>/dev/null || true
        ;;
    esac
  done
}

# Keep the loader's matching C++ runtime ahead of game and firmware libraries.
# Every current unityloader/plugin build is one deployment unit, so falling
# back to another libstdc++ would silently defeat that contract.
prepare_unityloader_private_libs() {
  local private_libs="$GAMEDIR/unityloader.libs"
  local library
  for library in libstdc++.so.6 libgcc_s.so.1; do
    [ -r "$private_libs/$library" ] || {
      echo "$LOG_PREFIX missing unityloader private library: $private_libs/$library"
      return 1
    }
  done
  export LD_LIBRARY_PATH="$private_libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

run_unity_game() {
  local toml="$1" game_library_paths="${2:-}"
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

  chmod a+x "$GAMEDIR/unityloader"
  pm_platform_helper "$GAMEDIR/unityloader"
  restore_unity_handheld_input

  "$GAMEDIR/unityloader" "$toml" &
  local unity_pid=$!
  echo -500 > "/proc/$unity_pid/oom_score_adj" 2>/dev/null
  local victim
  for victim in $(pgrep -f 'pulseaudio|bluealsa' 2>/dev/null); do
    echo 800 > "/proc/$victim/oom_score_adj" 2>/dev/null
  done

  wait "$unity_pid"
  restore_unity_handheld_input
  pm_finish
}
