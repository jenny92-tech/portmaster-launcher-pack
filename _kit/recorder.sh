#!/bin/bash
# INPUT:  ffmpeg kmsgrab、DRM 设备与 REC_* 录屏参数
# OUTPUT: recorder_probe/start/stop/assemble/status/frame_count()；JPEG 帧与 MP4
# POS:    提供无顶层执行副作用的共享掌机录屏引擎
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech
#
# recorder.sh — shared screen-recorder engine (kmsgrab frame capture).
#
# A PURE FUNCTION LIBRARY: no top-level side effects. The standalone recorder
# app inlines it through assemble.sh; `_kit/build_recorder_tool.sh` also emits
# the self-contained CLI used for SSH verification and by the app's Lua UI.
#
# Strategy: the TrimUI Brick has no HDMI/DP video output, so the only viable
# recording path is grabbing the DRM scanout plane with ffmpeg kmsgrab at a
# low framerate (5 fps default) into JPEG frames. NO video encoding runs while
# the game plays (near-zero CPU cost); the frame sequence is encoded into an
# MP4 afterwards, when nothing else needs the CPU.
#
# Provided functions:
#   recorder_probe                print environment / feasibility info
#   recorder_start                begin background frame capture
#   recorder_stop                 stop capture + assemble MP4
#   recorder_assemble DIR [FPS]   assemble a session dir into MP4
#   recorder_status               print machine-parseable state
#   recorder_frame_count DIR      count captured frames
#
# Variables read (all optional):
#   REC_FFMPEG      ffmpeg binary (default: ./ffmpeg next to script, then PATH)
#   REC_DIR         output root (default: /mnt/SDCARD/videos)
#   REC_FPS         capture framerate (default: 5)
#   REC_DRM_DEVICE  DRM card (default: first readable /dev/dri/card*)
#   REC_FORMAT      hwdownload pixel format (default: bgr0)
#   REC_Q           JPEG quality 2..31 (default: 5)
#   REC_PRESET      x264 preset for assembly (default: veryfast)
#   REC_CRF         x264 CRF for assembly (default: 23)
#   REC_KEEP_FRAMES delete frames after successful assembly (default: keep)
#   REC_LOG_FILE    append one-line entries to this log

recorder_log() { [ -n "${REC_LOG_FILE:-}" ] && printf '%s\n' "$(date +%H:%M:%S) $*" >>"$REC_LOG_FILE" || true; }

# ── environment discovery ──────────────────────────────────────────────

recorder_ffmpeg() {
  if [ -n "${REC_FFMPEG:-}" ]; then
    if [ -x "$REC_FFMPEG" ]; then printf '%s\n' "$REC_FFMPEG"; return 0; fi
    return 1
  fi
  local f
  for f in "$(dirname "$0")/ffmpeg" ./ffmpeg /mnt/SDCARD/videos/ffmpeg; do
    if [ -x "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
  if command -v ffmpeg >/dev/null 2>&1; then printf '%s\n' ffmpeg; return 0; fi
  return 1
}

recorder_drm_device() {
  if [ -n "${REC_DRM_DEVICE:-}" ]; then printf '%s\n' "$REC_DRM_DEVICE"; return 0; fi
  local d
  for d in /dev/dri/card0 /dev/dri/card1 /dev/dri/card2; do
    if [ -r "$d" ]; then printf '%s\n' "$d"; return 0; fi
  done
  return 1
}

recorder_out_dir() { printf '%s\n' "${REC_DIR:-/mnt/SDCARD/videos}"; }

# ── probe ──────────────────────────────────────────────────────────────

recorder_probe() {
  local ffmpeg drm out
  ffmpeg="$(recorder_ffmpeg)" || { echo "ERROR: no ffmpeg found (set REC_FFMPEG or place ffmpeg next to this script)"; return 1; }
  drm="$(recorder_drm_device)" || { echo "ERROR: no readable /dev/dri/card* (KMS unavailable?)"; return 1; }
  out="$(recorder_out_dir)"

  echo "ffmpeg: $ffmpeg"
  "$ffmpeg" -hide_banner -version | head -1 | sed 's/^/  /' || true
  if "$ffmpeg" -hide_banner -devices 2>/dev/null | grep -q kmsgrab; then
    echo "kmsgrab indev: available"
  else
    echo "kmsgrab indev: MISSING — this ffmpeg cannot capture (wrong build)"
  fi
  echo "drm device: $drm $([ -e "$drm" ] && ls -l "$drm" | awk '{print $1, $3, $4}' || echo '(missing)') "
  echo "output dir: $out"
  if [ -d "$out" ]; then
    echo "output dir: writable=$([ -w "$out" ] && echo yes || echo no)"
  else
    echo "output dir: does not exist (created on start)"
  fi
  echo "capture: ${REC_FPS:-5} fps -> mjpeg q=${REC_Q:-5}, format ${REC_FORMAT:-bgr0}"
}

# ── capture lifecycle ──────────────────────────────────────────────────

recorder_start() {
  local ffmpeg drm out session log_file fps q fmt
  ffmpeg="$(recorder_ffmpeg)" || { echo "ERROR: no ffmpeg found (set REC_FFMPEG or place ffmpeg next to this script)"; return 1; }
  drm="$(recorder_drm_device)" || { echo "ERROR: no readable /dev/dri/card* (KMS unavailable?)"; return 1; }
  out="$(recorder_out_dir)"
  fps="${REC_FPS:-5}"
  q="${REC_Q:-5}"
  fmt="${REC_FORMAT:-bgr0}"

  if [ -f "$out/.recorder.state" ]; then
    local active
    active="$(recorder_status 2>/dev/null | grep '^state=' | cut -d= -f2 || true)"
    if [ "$active" = "recording" ]; then
      echo "ERROR: capture already running"
      return 1
    fi
  fi

  mkdir -p "$out"
  session="rec_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$out/$session"
  log_file="$out/recorder.log"
  REC_LOG_FILE="$log_file"
  export REC_LOG_FILE

  printf 'session=%s\nfps=%s\nfmt=%s\nq=%s\ndrm=%s\n' \
    "$session" "$fps" "$fmt" "$q" "$drm" > "$out/.recorder.state"

  recorder_log "start session=$session drm=$drm fps=$fps fmt=$fmt q=$q ffmpeg=$ffmpeg"

  # setsid detaches the capture into its own session so no frontend/app
  # process-group teardown can kill it between app launches.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$ffmpeg" -hide_banner -loglevel warning \
      -f kmsgrab -framerate "$fps" -i "$drm" \
      -vf "hwdownload,format=$fmt,fps=$fps" \
      -c:v mjpeg -q:v "$q" \
      -f image2 "$out/$session/frame_%05d.jpg" \
      >>"$log_file" 2>&1 &
  else
    "$ffmpeg" -hide_banner -loglevel warning \
      -f kmsgrab -framerate "$fps" -i "$drm" \
      -vf "hwdownload,format=$fmt,fps=$fps" \
      -c:v mjpeg -q:v "$q" \
      -f image2 "$out/$session/frame_%05d.jpg" \
      >>"$log_file" 2>&1 &
  fi
  printf '%s\n' "$!" > "$out/.recorder.pid"

  # quick sanity: give it a moment and check frames actually appear.
  sleep 2
  if [ -z "$(ls "$out/$session"/frame_*.jpg 2>/dev/null || true)" ]; then
    echo "WARN: no frames after 2s — plane may be blank/unsupported (try REC_FORMAT=xrgb32)"
    echo "  log tail:"; tail -5 "$log_file" | sed 's/^/    /' || true
  fi
  echo "recording (pid $(cat "$out/.recorder.pid")) — frames: $(recorder_frame_count "$out/$session")"
}

recorder_stop() {
  local out state session pid frames n
  out="$(recorder_out_dir)"
  state="$out/.recorder.state"
  if [ ! -f "$state" ]; then echo "ERROR: no active session (no $state)"; return 1; fi
  # shellcheck disable=SC1090
  . "$state"
  session="${session:-}"
  if [ -z "$session" ] || [ ! -d "$out/$session" ]; then
    echo "ERROR: session dir missing: $out/$session"
    return 1
  fi

  pid=""
  [ -f "$out/.recorder.pid" ] && pid="$(cat "$out/.recorder.pid")"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "stopping capture pid $pid"
    kill "$pid" 2>/dev/null || true
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 50 ]; do
      sleep 0.2; n=$((n + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "WARN: ffmpeg did not exit, killing"
      kill -9 "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  else
    echo "no live capture pid — assembling existing frames"
  fi
  rm -f "$out/.recorder.pid"

  frames="$(recorder_frame_count "$out/$session")"
  if [ "$frames" -lt 1 ]; then
    echo "ERROR: session has no frames — nothing to assemble"
    rm -f "$state"
    return 1
  fi
  echo "session captured $frames frames (~$((frames / ${fps:-5}))s at ${fps:-5} fps)"

  local mp4
  mp4="$(recorder_assemble "$out/$session" "$fps")" || return 1
  printf '%s\n' "$mp4" > "$out/.recorder.last"
  rm -f "$state"
  echo "saved: $mp4"
}

recorder_assemble() {
  local dir="$1" fps="${2:-${REC_FPS:-5}}" preset crf mp4 n
  if [ ! -d "$dir" ]; then echo "ERROR: session dir missing: $dir"; return 1; fi
  preset="${REC_PRESET:-veryfast}"
  crf="${REC_CRF:-23}"
  n="$(recorder_frame_count "$dir")"
  if [ "$n" -lt 1 ]; then echo "ERROR: no frames in $dir"; return 1; fi

  mp4="${dir%/*}/$(basename "$dir").mp4"
  # -pattern_type glob: quoted, so the shell leaves the pattern for ffmpeg.
  "$(recorder_ffmpeg)" -hide_banner -loglevel warning \
    -framerate "$fps" -pattern_type glob -i "$dir/frame_*.jpg" \
    -c:v libx264 -preset "$preset" -crf "$crf" -pix_fmt yuv420p \
    -movflags +faststart \
    "$mp4" \
    || { echo "ERROR: assembly failed"; return 1; }
  if [ "${REC_KEEP_FRAMES:-0}" = "1" ]; then
    rm -f "$dir"/frame_*.jpg
    recorder_log "removed frames for $dir"
  fi
  local du_h
  du_h="$([ -f "$mp4" ] && du -h "$mp4" | cut -f1 || echo "?")"
  echo "assembled $n frames -> $mp4 ($du_h)" >&2
  printf '%s\n' "$mp4"
}

recorder_frame_count() {
  ls "$1"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' '
}

# ── status (machine-parseable) ─────────────────────────────────────────

recorder_status() {
  local out state session pid frames fps last
  out="$(recorder_out_dir)"
  state="$out/.recorder.state"
  last=""
  [ -f "$out/.recorder.last" ] && last="$(cat "$out/.recorder.last")"
  if [ ! -f "$state" ]; then
    printf 'state=nosession\nlast_video=%s\n' "$last"
    return 0
  fi
  # shellcheck disable=SC1090
  . "$state"
  session="${session:-}"; fps="${fps:-}"; pid=""
  [ -f "$out/.recorder.pid" ] && pid="$(cat "$out/.recorder.pid")"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    frames="$(recorder_frame_count "$out/$session" 2>/dev/null || echo 0)"
    printf 'state=recording\nsession=%s\nfps=%s\nframes=%s\nlast_video=%s\n' \
      "$session" "$fps" "$frames" "$last"
  else
    frames="$(recorder_frame_count "$out/$session" 2>/dev/null || echo 0)"
    printf 'state=idle\nsession=%s\nfps=%s\nframes=%s\nlast_video=%s\n' \
      "$session" "$fps" "$frames" "$last"
  fi
}
