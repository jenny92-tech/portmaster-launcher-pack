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

resolve_render_scale 75
[ "$RENDER_SCALE_PERCENT:$RENDER_W:$RENDER_H" = "75:720:540" ]

printf '%s\n' \
  '[device]' \
  'displayWidth=1' \
  'displayHeight=1' \
  '' \
  '[gpu]' \
  'renderScaleDivisor = 4' \
  'renderScaleLinear = false' \
  'renderWidth = 320' \
  'renderHeight = 180' \
  > "$TMP/config.toml"

apply_display_resolution "$TMP/config.toml"
apply_render_scale "$TMP/config.toml"

grep -Fq 'displayWidth=960' "$TMP/config.toml"
grep -Fq 'displayHeight=720' "$TMP/config.toml"
grep -Fq 'renderScalePercent = 75' "$TMP/config.toml"
grep -Fq 'renderScaleSharp = true' "$TMP/config.toml"
grep -Fq 'renderWidth = 0' "$TMP/config.toml"
grep -Fq 'renderHeight = 0' "$TMP/config.toml"
! grep -Fq 'renderScaleDivisor' "$TMP/config.toml"
! grep -Fq 'renderScaleLinear' "$TMP/config.toml"

resolve_render_scale invalid
[ "$RENDER_SCALE_PERCENT:$RENDER_W:$RENDER_H" = "100:960:720" ]
