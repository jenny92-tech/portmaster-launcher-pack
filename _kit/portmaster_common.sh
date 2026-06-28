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
    if ! pactl list short sinks 2>/dev/null | grep -qv auto_null; then
      pactl load-module module-alsa-sink device=default tsched=0 >/dev/null 2>&1
      local sink
      sink=$(pactl list short sinks 2>/dev/null | grep -v auto_null | head -1 | awk '{print $2}')
      [ -n "$sink" ] && pactl set-default-sink "$sink" >/dev/null 2>&1
      echo "$LOG_PREFIX pulse -> ALSA default ($sink)"
    fi
  else
    echo "$LOG_PREFIX no pulseaudio on this CFW — direct ALSA (double-open may hang)"
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
