#!/usr/bin/env bash
# INPUT:  tools/record_screen.sh、临时 ffmpeg 替身与录屏状态夹具
# OUTPUT: 采帧/停止/合成状态机、错误路径与 CLI 断言结果
# POS:    录屏引擎无需真实 DRM 或编码器的生命周期回归测试
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech
#
# Screen recorder engine tests: state machine (start/status/stop/assemble),
# error paths, and the standalone CLI tool. Uses a stub ffmpeg so no DRM
# device or real binary is required.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/ffmpeg" <<'SH'
#!/bin/sh
# Stub recorder ffmpeg:
#   kmsgrab capture  -> write frame_%05d.jpg files until STOP_FILE appears
#   frame_*.jpg glob -> assembly: touch the output mp4 (last argument)
#   -version / -devices / -encoders -> canned answers
STOP_FILE="$STOP_FILE"
if printf '%s\n' "$*" | grep -q kmsgrab; then
  template=""
  for a in "$@"; do
    case "$a" in *frame_%05d*) template="$a" ;; esac
  done
  dir="${template%/*}"
  n=1
  while :; do
    : > "$(printf '%s/frame_%05d.jpg' "$dir" "$n")"
    n=$((n + 1))
    [ -f "$STOP_FILE" ] && break
    sleep 0.02
  done
  exit 0
fi
if printf '%s\n' "$*" | grep -Fq 'frame_*.jpg'; then
  last=""
  for a in "$@"; do last="$a"; done
  : > "$last"
  exit 0
fi
case "$*" in
  *-version*)
    echo "ffmpeg version 7.1 stub"
    ;;
  *-devices*)
    echo " D.  kmsgrab  KMS grab"
    ;;
  *-encoders*)
    echo " V....D libx264              H.264"
    echo " V....D mjpeg                JPEG"
    ;;
esac
exit 0
SH
chmod +x "$tmp/bin/ffmpeg"

TOOL="$ROOT/tools/record_screen.sh"
REC_DIR="$tmp/videos"
export REC_DIR REC_FFMPEG="$tmp/bin/ffmpeg" REC_DRM_DEVICE=/dev/dri/card0
export REC_FPS=5 REC_Q=5 REC_PRESET=ultrafast REC_CRF=26
export STOP_FILE="$tmp/stop"
export PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ── probe ──────────────────────────────────────────────────────────────
out="$("$TOOL" probe)"
grep -Fq "ffmpeg: $tmp/bin/ffmpeg" <<<"$out"
grep -Fq "kmsgrab indev: available" <<<"$out"
grep -Fq "drm device: /dev/dri/card0" <<<"$out"

# ── start ──────────────────────────────────────────────────────────────
out="$("$TOOL" start)"
grep -Fq "recording (pid" <<<"$out"
[ -f "$REC_DIR/.recorder.state" ]
[ -f "$REC_DIR/.recorder.pid" ]

status="$("$TOOL" status)"
grep -Fq "state=recording" <<<"$status"
grep -E "^frames=[0-9]+$" <<<"$status" | grep -qv "frames=0" || {
  echo "expected captured frames in status" >&2; exit 1
}

# double start must fail
if "$TOOL" start >/dev/null 2>&1; then
  echo "double start should fail" >&2; exit 1
fi

# ── stop + assemble ────────────────────────────────────────────────────
: > "$STOP_FILE"
out="$("$TOOL" stop)"
grep -Fq "saved:" <<<"$out"
saved="$(grep '^saved:' <<<"$out" | head -1 | cut -d' ' -f2)"
[ -f "$saved" ]
[ -f "$REC_DIR/.recorder.last" ]
[ "$(cat "$REC_DIR/.recorder.last")" = "$saved" ]
[ ! -e "$REC_DIR/.recorder.state" ]

status="$("$TOOL" status)"
grep -Fq "state=nosession" <<<"$status"
grep -Fq "last_video=$saved" <<<"$status"

# frames kept by default, MP4 is a sibling of the session dir
session_dir="${saved%.mp4}"
[ -d "$session_dir" ]
[ "$(ls "$session_dir"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ]

# ── assemble on an explicit dir (re-run after reboot) ──────────────────
rm -f "$saved"
"$TOOL" assemble "$session_dir" >/dev/null
[ -f "$saved" ]

# ── error paths ────────────────────────────────────────────────────────
REC_FFMPEG=/nonexistent/ffmpeg "$TOOL" start >/dev/null 2>&1 && {
  echo "start with missing ffmpeg should fail" >&2; exit 1
}
REC_FFMPEG=/nonexistent/ffmpeg "$TOOL" probe >/dev/null 2>&1 && {
  echo "probe with missing ffmpeg should fail" >&2; exit 1
}
"$TOOL" stop >/dev/null 2>&1 && {
  echo "stop without session should fail" >&2; exit 1
}
"$TOOL" assemble "$tmp/does-not-exist" >/dev/null 2>&1 && {
  echo "assemble of a missing dir should fail" >&2; exit 1
}

# ── generated tool is a self-contained copy of the engine ──────────────
grep -Fq "recorder_start()" "$TOOL"
grep -Fq "recorder_stop()" "$TOOL"
grep -Fq "recorder_status()" "$TOOL"
grep -Fq "recorder_assemble()" "$TOOL"
grep -Fq 'source "' "$TOOL" && {
  echo "tool must be self-contained (no external source)" >&2
  grep -n 'source "' "$TOOL" | head -5 >&2
  exit 1
}

echo "recorder engine tests: PASS"
