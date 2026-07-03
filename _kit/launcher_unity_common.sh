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
#   PORT_NAME, LOG_PREFIX, controlfolder, GAMEDIR, CONFDIR, ESUDO,
#   GPTOKEYB, sdl_controllerconfig, DISPLAY_WIDTH, DISPLAY_HEIGHT
#
# Provides: find_godot_binary, run_godot_launcher, apply_button_remap,
#           run_unity_game

# ── Godot binary discovery for the stage-1 launcher UI.
# Arg $1 = which godot generation the port's bootstrap.pck needs:
#   "godot4" (default) → tier 1 local godot.mono/godot, then tier 2 PortMaster
#                        godot_4.x squashfs. (HK: Godot-4 pck.)
#   "frt3"             → tier 3 PortMaster frt_3.* squashfs (highest 3.x).
#                        (hk + heishenhua: Godot-3 pck — picking a godot4
#                        binary would fail to load it, so frt3 is forced.)
# Sets GODOT_BIN, GODOT_KIND ("godot4_local"|"godot4_squash"|"frt3"|""),
# GODOT_FRT_NAME (the chosen frt binary basename, frt3 only) and GODOT_RT_DIR
# if a squashfs got mounted. Returns 1 if nothing usable. ────
find_godot_binary() {
  local want="${1:-godot4}"
  GODOT_BIN=""; GODOT_KIND=""; GODOT_RT_DIR=""; GODOT_FRT_NAME=""

  if [ "$want" = "godot4" ]; then
    # Tier 1: port-local godot.mono / godot (godot 4 SDL2 fork, ~60 MB)
    local c
    for c in "$GAMEDIR/godot.mono" "$GAMEDIR/godot"; do
      if [ -x "$c" ]; then
        GODOT_BIN="$c"; GODOT_KIND="godot4_local"
        echo "$LOG_PREFIX local godot: $GODOT_BIN"
        return 0
      fi
    done
    # Tier 2: PortMaster libs/godot_4.x.squashfs (stock godot 4)
    local squash
    squash=$(ls "$controlfolder/libs"/godot*.squashfs 2>/dev/null | sort -V | tail -1)
    if [ -n "$squash" ]; then
      GODOT_RT_DIR="$GAMEDIR/godot_rt"
      mkdir -p "$GODOT_RT_DIR"
      mount | grep -q "$GODOT_RT_DIR" || $ESUDO mount "$squash" "$GODOT_RT_DIR"
      GODOT_BIN=$(find "$GODOT_RT_DIR" -maxdepth 2 -name 'godot*' -type f -perm -u+x 2>/dev/null | head -1)
      if [ -n "$GODOT_BIN" ]; then
        GODOT_KIND="godot4_squash"
        echo "$LOG_PREFIX PortMaster godot squash: $squash -> $GODOT_BIN"
        return 0
      fi
    fi
  fi

  if [ "$want" = "frt3" ]; then
    # Tier 3: PortMaster libs/frt_3.*.squashfs (Godot 3.x frt fork — KMS
    # handhelds; needs gptokeyb + hacksdl for input). Pick the highest 3.x by
    # version. Our bootstrap.pck is PCK format v1 (Godot 3), readable by ANY
    # frt_3.x but NOT frt_4.x (format v3) — so the glob is pinned to 3.* and
    # the binary name (e.g. frt_3.6) is derived from whichever squashfs won.
    local squash
    squash=$(ls "$controlfolder/libs"/frt_3.*.squashfs 2>/dev/null | sort -V | tail -1)
    if [ -n "$squash" ]; then
      GODOT_FRT_NAME="$(basename "$squash" .squashfs)"   # e.g. frt_3.6
      GODOT_RT_DIR="$HOME/godot"
      $ESUDO mkdir -p "$GODOT_RT_DIR"
      $ESUDO umount "$GODOT_RT_DIR" 2>/dev/null
      $ESUDO mount "$squash" "$GODOT_RT_DIR"
      GODOT_BIN="$GODOT_RT_DIR/$GODOT_FRT_NAME"; GODOT_KIND="frt3"
      echo "$LOG_PREFIX $GODOT_FRT_NAME: $GODOT_BIN"
      return 0
    fi
  fi

  echo "$LOG_PREFIX no godot binary ($want) — UI will be skipped"
  return 1
}

# Run the stage-1 launcher UI. Handles godot4 SDL2-fork vs frt3 CLI/input
# differences. Args: $1 = main pck path, $2... = extra args. Sets launcher_exit;
# unmounts any squashfs it mounted (except the port-local tier-1 binary).
run_godot_launcher() {
  local main_pack="$1"; shift
  local extra="$@"

  case "$GODOT_KIND" in
    godot4_local|godot4_squash)
      # godot 4 SDL2 fork: SDL_VIDEODRIVER=dummy because the fork drives KMS/EGL
      # itself; libmali/libEGL live in standard /usr/lib (PortMaster omits them).
      LD_LIBRARY_PATH="/usr/lib:/usr/lib64:${LD_LIBRARY_PATH}" \
      SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=alsa \
      XDG_CONFIG_HOME="$CONFDIR" XDG_DATA_HOME="$CONFDIR" \
        "$GODOT_BIN" --display-driver sdl2 --rendering-driver opengl3 \
        --resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} \
        --main-pack "$main_pack" $extra
      launcher_exit=$?
      ;;
    frt3)
      # godot 3 frt: gptokeyb for input + hacksdl SDL2 joypad shim. Caller must
      # ship $GAMEDIR/hacksdl/hacksdl.aarch64.so + $GAMEDIR/${PORT_NAME}.gptk.
      export FRT_NO_EXIT_SHORTCUTS=FRT_NO_EXIT_SHORTCUTS
      export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
      $GPTOKEYB "$GODOT_FRT_NAME" -c "$GAMEDIR/${PORT_NAME}.gptk" &
      local gptokeyb_pid=$!
      pm_platform_helper "$GODOT_FRT_NAME"
      LD_PRELOAD="$GAMEDIR/hacksdl/hacksdl.aarch64.so" HACKSDL_DEVICE_DISABLE_0=2 \
      XDG_CONFIG_HOME="$CONFDIR" XDG_DATA_HOME="$CONFDIR" \
      GODOT_SILENCE_ROOT_WARNING=1 \
        "$GODOT_BIN" --resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} \
        --main-pack "$main_pack" $extra
      launcher_exit=$?
      kill $gptokeyb_pid 2>/dev/null; wait $gptokeyb_pid 2>/dev/null
      ;;
    *)
      launcher_exit=1
      ;;
  esac

  [ -n "$GODOT_RT_DIR" ] && [ "$GODOT_KIND" != "godot4_local" ] && \
    $ESUDO umount "$GODOT_RT_DIR" 2>/dev/null
}

# ── Stage-1 launcher UI: find the right godot, run it, act on the exit code.
# Identical across hk/heishenhua, so it lives here. Exit codes: 0 = user quit
# → pm_finish and exit the whole launcher; 42 = start the game; anything else =
# UI crashed → fall through and start the game anyway (never let a broken UI
# block the game). Args: $1 = godot generation (godot4|frt3), $2 = main pck. ──
run_launcher_ui() {
  local want="$1" pck="$2"
  if find_godot_binary "$want" && [ -f "$pck" ]; then
    echo "$LOG_PREFIX stage 1: launcher UI ($GODOT_BIN)"
    run_godot_launcher "$pck"
    echo "$LOG_PREFIX launcher exited: $launcher_exit"
    if [ "$launcher_exit" = "0" ]; then
      echo "$LOG_PREFIX user quit — back to menu."
      pm_finish; exit 0
    elif [ "$launcher_exit" != "42" ]; then
      echo "$LOG_PREFIX launcher UI failed ($launcher_exit) — starting game anyway."
    fi
  else
    echo "$LOG_PREFIX no $want launcher UI / bootstrap.pck — skipping, using current config"
  fi
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
  # Loong input can be left locked/stopped if a previous experimental launcher
  # or the loader's Start+Select fast-exit path bypasses normal teardown.
  rm -f /tmp/lock_loong_daemon 2>/dev/null || true

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
