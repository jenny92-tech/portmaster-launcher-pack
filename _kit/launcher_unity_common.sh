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
apply_display_resolution() {
  local toml="$1"
  sed -i "s/^displayWidth=.*/displayWidth=${RES_W}/" "$toml"
  sed -i "s/^displayHeight=.*/displayHeight=${RES_H}/" "$toml"
}

# ── [input.remap] upsert a/b/x/y into the section (replace if present, append
# if missing). sed can't add lines that don't exist, and a toml missing x/y
# lines makes the swap silently dead; awk self-heals, other lines/sections
# pass through verbatim. Args: $1=toml file, $2=a $3=b $4=x $5=y values. ───
apply_button_remap() {
  local toml="$1" a="$2" b="$3" x="$4" y="$5"
  awk -v a="$a" -v b="$b" -v x="$x" -v y="$y" '
    /^\[input\.remap\]/ { print; inblk=1; da=db=dx=dy=0; next }
    inblk && /^\[/ {
      if(!da) printf "a       = \"%s\"\n", a
      if(!db) printf "b       = \"%s\"\n", b
      if(!dx) printf "x       = \"%s\"\n", x
      if(!dy) printf "y       = \"%s\"\n", y
      inblk=0
    }
    inblk && /^a *=/ { printf "a       = \"%s\"\n", a; da=1; next }
    inblk && /^b *=/ { printf "b       = \"%s\"\n", b; db=1; next }
    inblk && /^x *=/ { printf "x       = \"%s\"\n", x; dx=1; next }
    inblk && /^y *=/ { printf "y       = \"%s\"\n", y; dy=1; next }
    { print }
    END { if(inblk){ if(!da)printf"a       = \"%s\"\n",a; if(!db)printf"b       = \"%s\"\n",b; if(!dx)printf"x       = \"%s\"\n",x; if(!dy)printf"y       = \"%s\"\n",y } }
  ' "$toml" > "$toml.tmp" && mv "$toml.tmp" "$toml"
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

run_unity_game() {
  local toml="$1"
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
