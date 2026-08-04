#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORTKIT_BIN="$ROOT/target/debug/portkit-launcher"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source "$ROOT/_kit/launcher_unity_common.sh"

LOG_PREFIX="[TEST]"
DISPLAY_WIDTH=960
DISPLAY_HEIGHT=720

portkit_launcher() {
  "$PORTKIT_BIN" "$@"
}

resolve_display_resolution auto auto
[ "$RES_W:$RES_H" = "960:720" ]

resolve_render_scale 2
[ "$RENDER_SCALE_DIVISOR:$RENDER_W:$RENDER_H" = "2:480:360" ]

printf '%s\n' \
  '[device]' \
  'displayWidth=1' \
  'displayHeight=1' \
  '' \
  '[gpu]' \
  'renderScaleDivisor = 4' \
  'renderWidth = 320' \
  'renderHeight = 180' \
  > "$TMP/config.toml"

apply_display_resolution "$TMP/config.toml"
apply_render_scale "$TMP/config.toml"

grep -Fq 'displayWidth=960' "$TMP/config.toml"
grep -Fq 'displayHeight=720' "$TMP/config.toml"
grep -Fq 'renderScaleDivisor = 2' "$TMP/config.toml"
grep -Fq 'renderWidth = 0' "$TMP/config.toml"
grep -Fq 'renderHeight = 0' "$TMP/config.toml"

resolve_render_scale invalid
[ "$RENDER_SCALE_DIVISOR:$RENDER_W:$RENDER_H" = "1:960:720" ]
