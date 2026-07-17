#!/bin/bash
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech
#
# PortMaster device-generic helpers — engine-agnostic, usable by ANY port
# (Unity, Godot, native …). A pure FUNCTION LIBRARY: no top-level side effects.
# Source it from a launcher AFTER the launcher's own preamble has set up
# controlfolder / GAMEDIR / CONFDIR and sourced control.txt.
#
# Variables the functions read (set by the launcher preamble):
#   PORT_NAME, LOG_PREFIX, GAMEDIR, CONFDIR
#
# Provides: audio_setup, memory_tuning, install_exit_trap

# ── Audio — branch by system, each does its own thing, neither touches the
# other. The pulseaudio + XDG_RUNTIME_DIR dance is a TrimUI-class workaround;
# MiniLoong must be left alone or its wayland breaks. ─────────────────────
audio_setup() {
  # MiniLoong (CFW=Loong, wayland/weston): the OS already runs audio AND sets
  # XDG_RUNTIME_DIR pointing at the wayland socket (/run). Touch NEITHER:
  # starting pulse is unneeded, and overriding XDG_RUNTIME_DIR cuts the loader
  # off from wayland → HK black screen / heishenhua 90° rotation (game would
  # fall back to GBM-direct, bypassing weston's transform=rotate-90).
  if [ "$CFW_NAME" = "Loong" ]; then
    echo "$LOG_PREFIX Loong: system audio + system XDG_RUNTIME_DIR left untouched (wayland)"
    return
  fi

  # TrimUI-class (KMSDRM, hw-exclusive ALSA, system does NOT set
  # XDG_RUNTIME_DIR): SDL + the Unity thunk both snd_pcm_open the hw device; the
  # 2nd blocks forever → black-screen hang. Run pulseaudio to mix, and give it a
  # writable runtime dir for its socket (the only reason we set XDG here).
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-${PORT_NAME}}"
  mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null && chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
  if pgrep -x pulseaudio >/dev/null 2>&1 || pgrep -x pipewire-pulse >/dev/null 2>&1; then
    echo "$LOG_PREFIX pulse/pipewire daemon already up"
  elif command -v pulseaudio >/dev/null 2>&1; then
    pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1
    sleep 1
  else
    echo "$LOG_PREFIX no pulseaudio on this CFW — direct ALSA (double-open may hang)"
  fi

  if command -v pactl >/dev/null 2>&1 && ! pactl list short sinks 2>/dev/null | grep -qv auto_null; then
    pactl load-module module-alsa-sink device=default tsched=0 >/dev/null 2>&1
    local sink
    sink=$(pactl list short sinks 2>/dev/null | grep -v auto_null | head -1 | awk '{print $2}')
    [ -n "$sink" ] && pactl set-default-sink "$sink" >/dev/null 2>&1
    echo "$LOG_PREFIX pulse -> ALSA default ($sink)"
  fi
}

# ── Memory tuning for 1 GB-RAM handhelds. TODO(measure): confirm RSS delta on
# device before trusting these. MALLOC_* are honored by glibc; ARENA_MAX=2 is
# the solid one (caps per-thread malloc arenas). GC_* are read by the game's
# Boehm GC (libmonobdwgc-2.0) — effect unverified on this Mono variant. ───
memory_tuning() {
  export MALLOC_ARENA_MAX=2
  export MALLOC_TRIM_THRESHOLD_=131072
  export MALLOC_MMAP_THRESHOLD_=131072
  # Boehm GC (IL2CPP runtime uses libgc) — unmap freed pages back to OS
  export GC_FORCE_UNMAP_ON_GCOLLECT=1
  export GC_UNMAP_THRESHOLD=1
}

# ── dmesg capture on exit (OOM-kill / segfault evidence) ────────────────
# Cheap one-shot: dumps the kernel ring buffer tail on exit so an OOM-kill /
# segfault leaves a post-mortem in dmesg_exit.log. (The periodic background
# sync was removed — a system-wide sync() every 1s risked I/O micro-stutter
# and only protected the debug log; the single sync here flushes it on exit.)
install_exit_trap() {
  trap '
    dmesg 2>/dev/null | tail -100 > "$GAMEDIR/dmesg_exit.log" 2>&1 || \
        echo "(dmesg unreadable)" > "$GAMEDIR/dmesg_exit.log"
    sync
  ' EXIT INT TERM
}

# ── love stage-1 UI (replaces run_launcher_ui frt3) ──────────────────────
# Per port: swap `run_launcher_ui frt3 "$GAMEDIR/bootstrap.pck"` for
# `run_love_launcher_ui` and point stage-2's env at `$LAUNCH_ENV`; stage-2 is
# otherwise untouched.
#
# UI files live in $GAMEDIR/love_ui/ (main.lua/kit.lua/conf.lua/ui.gptk/
# launcher_bg.png). The CJK font is taken from PortMaster's own NotoSansSC and
# passed to LÖVE by its validated real path (see _kit/love/README.md).
# Exit codes match run_launcher_ui: 0 = back to menu, 42 = start game.

_love_valid_font() { [ -f "$1" ] && [ "$(wc -c < "$1" 2>/dev/null || echo 0)" -gt 1000000 ]; }
_love_noto_src() {
  local t z inner
  t=$(ls "$controlfolder"/pylibs/pylibs/resources/NotoSans.tar.xz \
         "$controlfolder"/pylibs/resources/NotoSans.tar.xz 2>/dev/null | head -1)
  [ -n "$t" ] && { echo "$t"; return; }
  z="$controlfolder/pylibs.zip"; [ -f "$z" ] || return
  inner=$(unzip -l "$z" 2>/dev/null | grep -oE '[^ ]*NotoSans\.tar\.xz' | head -1)
  [ -n "$inner" ] && echo "zip:$z:$inner"
}
_love_unpack_noto() {
  local src="$1" dst="$2" member="${3:-}" pipe rest
  $ESUDO mkdir -p "$dst" 2>/dev/null || return 1
  case "$src" in
    zip:*) rest="${src#zip:}"; pipe="unzip -p '${rest%%:*}' '${rest#*:}' | xz -dc" ;;
    *)     pipe="xz -dc '$src'" ;;
  esac
  $ESUDO sh -c "$pipe | tar xf - -C '$dst' $member" 2>/dev/null
  _love_valid_font "$dst/NotoSansSC-Regular.ttf"
}
_love_provide_font() {
  local ui_dir="$1" out="$1/font.ttf" std="${PM_RESOURCE_DIR:-$controlfolder/resources}" f src
  unset LOVE_FONT_PATH

  # Prefer a validated shared file and pass its real path through unchanged.
  # Kit removes a stale per-launcher copy only after it has successfully read
  # this shared source into FileData, preserving a safe upgrade fallback.
  for f in "$std/NotoSansSC-Regular.ttf" "$controlfolder/pylibs/resources/NotoSansSC-Regular.ttf"; do
    if _love_valid_font "$f"; then
      LOVE_FONT_PATH="$f"
      echo "$LOG_PREFIX font -> $LOVE_FONT_PATH"; return 0
    fi
  done

  src="$(_love_noto_src || true)"
  if [ -n "$src" ]; then
    # Unpack into PortMaster's standard resource dir so its own GUI benefits too.
    if _love_unpack_noto "$src" "$std"; then
      LOVE_FONT_PATH="$std/NotoSansSC-Regular.ttf"
      echo "$LOG_PREFIX font -> $LOVE_FONT_PATH (repaired from $src)"; return 0
    fi
  fi

  # Compatibility fallback for a device whose shared resource location cannot
  # be repaired. Existing old caches stay usable; otherwise extract only SC.
  if _love_valid_font "$out"; then
    LOVE_FONT_PATH="$out"
    echo "$LOG_PREFIX font -> $LOVE_FONT_PATH (local fallback)"; return 0
  fi
  if [ -n "$src" ]; then
    if _love_unpack_noto "$src" "$ui_dir" NotoSansSC-Regular.ttf && mv -f "$ui_dir/NotoSansSC-Regular.ttf" "$out" && _love_valid_font "$out"; then
      LOVE_FONT_PATH="$out"
      echo "$LOG_PREFIX font -> $LOVE_FONT_PATH (extracted fallback from $src)"; return 0
    fi
  fi
  unset LOVE_FONT_PATH
  echo "$LOG_PREFIX WARN: no CJK font — love falls back to its built-in (latin only)"; return 1
}

# run_love_launcher_ui [ui_dir]   (default $GAMEDIR/love_ui)
# Sets launcher_exit and LAUNCH_ENV.
run_love_launcher_ui() {
  local ui_dir="${1:-$GAMEDIR/love_ui}" love_txt
  LAUNCH_ENV="$ui_dir/launch_config.env"
  love_txt=$(ls "$controlfolder"/runtimes/love_*/love.txt 2>/dev/null | sort -V | tail -1)
  if [ -z "$love_txt" ] || [ ! -f "$ui_dir/main.lua" ]; then
    echo "$LOG_PREFIX no love runtime / main.lua — skipping settings UI, using current config"
    launcher_exit=1
    return
  fi
  _love_provide_font "$ui_dir" || true
  (   # Display env stays in this subshell — leaking it breaks the stage-2 game.
    export LOVE_IDENTITY="${PORT_NAME:-portmaster}_launcher"
    export LOVE_WINDOW_TITLE="${PORT_NAME:-PortMaster} Launcher"
    if [ -n "${LOVE_FONT_PATH:-}" ]; then export LOVE_FONT_PATH; else unset LOVE_FONT_PATH; fi
    source "$love_txt"
    export LIBGL_ES=2 LIBGL_GL=21
    local wl_dir="" wl_disp="${WAYLAND_DISPLAY:-wayland-0}" d
    for d in "$XDG_RUNTIME_DIR" "/run" "/run/user/$(id -u 2>/dev/null)" "/var/run"; do
      [ -n "$d" ] || continue
      if [ -S "$d/$wl_disp" ]; then wl_dir="$d"; break; fi
      if [ -S "$d/wayland-0" ]; then wl_dir="$d"; wl_disp="wayland-0"; break; fi
    done
    if [ -n "$wl_dir" ]; then
      export XDG_RUNTIME_DIR="$wl_dir" WAYLAND_DISPLAY="$wl_disp" SDL_VIDEODRIVER=wayland
      unset LIBGL_FB
      echo "$LOG_PREFIX love display=wayland ($XDG_RUNTIME_DIR/$WAYLAND_DISPLAY)"
    else
      unset SDL_VIDEODRIVER WAYLAND_DISPLAY
      export LIBGL_FB=4; [ ! -e "/dev/dri/card0" ] && export LIBGL_FB=2
      echo "$LOG_PREFIX love display=kms FB=$LIBGL_FB"
    fi
    $GPTOKEYB "$LOVE_GPTK" -c "$ui_dir/ui.gptk" &
    local gpid=$!
    pm_platform_helper "$LOVE_GPTK" 2>/dev/null || true
    cd "$ui_dir"
    $LOVE_RUN "$ui_dir"
    local le=$?
    kill $gpid 2>/dev/null; wait $gpid 2>/dev/null
    exit $le
  )
  launcher_exit=$?
  unset LOVE_FONT_PATH
  if [ "$launcher_exit" = "0" ]; then
    echo "$LOG_PREFIX launcher: back to menu"
    pm_finish; exit 0
  elif [ "$launcher_exit" != "42" ]; then
    echo "$LOG_PREFIX launcher failed ($launcher_exit) — starting game anyway"
  fi
}
