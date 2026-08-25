#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
runtime="$(mktemp -d /tmp/xdg-audio-test.XXXXXX)"
socket_pid=""
cleanup() {
  if [ -n "$socket_pid" ]; then
    kill "$socket_pid" 2>/dev/null || true
    wait "$socket_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp" "$runtime"
}
trap cleanup EXIT

mkdir -p "$tmp/bin" "$runtime/pulse"
TEST_VALID_SOCKET="$runtime/pulse/native"
export TEST_VALID_SOCKET

python3 - "$TEST_VALID_SOCKET" <<'PY' &
import socket
import sys
import time

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen(1)
time.sleep(30)
PY
socket_pid=$!

for _ in $(seq 1 50); do
  [ -S "$TEST_VALID_SOCKET" ] && break
  sleep 0.02
done
[ -S "$TEST_VALID_SOCKET" ]

cat > "$tmp/bin/pgrep" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$tmp/bin/pactl" <<'SH'
#!/bin/sh
case "$1" in
  info)
    [ "${PULSE_SERVER:-}" = "unix:$TEST_VALID_SOCKET" ]
    ;;
  list)
    [ "${PULSE_SERVER:-}" = "unix:$TEST_VALID_SOCKET" ] || exit 1
    printf '0\ttest_sink\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tRUNNING\n'
    ;;
  load-module|set-default-sink)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$tmp/bin/pgrep" "$tmp/bin/pactl"

PATH="$tmp/bin:$PATH"
CFW_NAME=""
PORT_NAME="audio-test-current"
LOG_PREFIX="[audio-test]"
XDG_RUNTIME_DIR="$tmp/current-runtime"
export PATH CFW_NAME PORT_NAME LOG_PREFIX XDG_RUNTIME_DIR
unset PULSE_SERVER SDL_AUDIODRIVER

source "$ROOT/_kit/portmaster_common.sh"
audio_setup > "$tmp/output"
output="$(< "$tmp/output")"

[ "$PULSE_SERVER" = "unix:$TEST_VALID_SOCKET" ]
[ "$SDL_AUDIODRIVER" = "pulseaudio" ]
grep -Fq "pulse socket -> $TEST_VALID_SOCKET" <<<"$output"
grep -Fq 'pulse/pipewire daemon already up; locating its socket' <<<"$output"

echo "portmaster common audio: PASS"
