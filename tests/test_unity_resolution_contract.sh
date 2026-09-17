#!/usr/bin/env bash
# INPUT:  launcher_unity_common.sh、本机 PortKit 调试二进制与临时 TOML
# OUTPUT: 物理分辨率、渲染比例和 Unity TOML 更新断言结果
# POS:    Unity 共享显示参数与原生配置工具的契约回归测试
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORTKIT_BIN="$ROOT/target/debug/portkit-launcher"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source "$ROOT/_kit/launcher_unity_common.sh"

LOG_PREFIX="[TEST]"
DISPLAY_WIDTH=960
DISPLAY_HEIGHT=720

PORTKIT_CALLS=0
portkit_launcher() {
  PORTKIT_CALLS=$((PORTKIT_CALLS + 1))
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

configure_unity_display "$TMP/config.toml" auto auto 75
[ "$PORTKIT_CALLS" = 1 ]

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

for percent in 100 75 50; do
  configure_unity_display "$TMP/config.toml" 1280 720 "$percent"
  [ "$RES_W:$RES_H" = "1280:720" ]
  [ "$RENDER_W:$RENDER_H" = "$((1280 * percent / 100)):$((720 * percent / 100))" ]
  grep -Fq "renderScalePercent = $percent" "$TMP/config.toml"
done

# A failed atomic write must reach the caller, not launch with partial settings.
portkit_launcher() { return 55; }
if configure_unity_display "$TMP/config.toml" auto auto 75; then
  echo "configure_unity_display swallowed a write failure" >&2
  exit 1
else
  [ "$?" = 55 ]
fi
