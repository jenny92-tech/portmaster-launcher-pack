#!/usr/bin/env bash
# INPUT:  launcher_unity_common.sh、本机 PortKit 调试二进制与临时 TOML
# OUTPUT: 显示/渲染分辨率、内存模式、配置路径与写入失败断言结果
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

CALL_LOG="$TMP/calls"
touch "$CALL_LOG"
portkit_launcher() {
  printf 'call\n' >> "$CALL_LOG"
  "$PORTKIT_BIN" "$@"
}

resolve_display_resolution auto auto
[ "$RES_W:$RES_H" = "960:720" ]

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
[ "$(wc -l < "$CALL_LOG" | tr -d ' ')" = 1 ]
[ "$RES_W:$RES_H:$RENDER_W:$RENDER_H" = "960:720:720:540" ]

grep -Fq 'displayWidth=960' "$TMP/config.toml"
grep -Fq 'displayHeight=720' "$TMP/config.toml"
grep -Fq 'renderScalePercent = 75' "$TMP/config.toml"
grep -Fq 'renderScaleSharp = true' "$TMP/config.toml"
grep -Fq 'renderWidth = 0' "$TMP/config.toml"
grep -Fq 'renderHeight = 0' "$TMP/config.toml"
! grep -Fq 'renderScaleDivisor' "$TMP/config.toml"
! grep -Fq 'renderScaleLinear' "$TMP/config.toml"

if configure_unity_display "$TMP/config.toml" auto auto invalid; then
  echo "accepted an invalid render selection" >&2
  exit 1
fi
[ "$(wc -l < "$CALL_LOG" | tr -d ' ')" = 1 ]

for percent in 100 75 50; do
  configure_unity_display "$TMP/config.toml" 1280 720 "$percent"
  [ "$RES_W:$RES_H" = "1280:720" ]
  [ "$RENDER_W:$RENDER_H" = "$((1280 * percent / 100)):$((720 * percent / 100))" ]
  grep -Fq "renderScalePercent = $percent" "$TMP/config.toml"
done

# A different working directory must not redirect the managed config. The
# Game preset choice preserves exact dimensions and the existing filter.
mkdir -p "$TMP/game with spaces" "$TMP/unrelated cwd"
GAMEDIR="$TMP/game with spaces"
cat > "$GAMEDIR/config.toml" <<'TOML'
[device] # commented headers are legal TOML
displayWidth=960
displayHeight=720
[gpu]
renderWidth=640
renderHeight=480
renderScaleSharp=false
[paths]
game_files='./gamedata/'
TOML
printf "sentinel='leave alone'\n" > "$TMP/unrelated cwd/config.toml"
cd "$TMP/unrelated cwd"
resolve_port_toml
[ "$PORT_TOML" = "$GAMEDIR/config.toml" ]
for mode in low_memory balanced performance; do
  configure_unity_display "$PORT_TOML" auto auto config "$mode"
  [ "$RES_W:$RES_H:$RENDER_W:$RENDER_H" = "960:720:640:480" ]
  grep -Fq "memory_mode = \"$mode\"" "$PORT_TOML"
done
grep -Fq 'renderWidth=640' "$PORT_TOML"
grep -Fq 'renderScaleSharp=false' "$PORT_TOML"
grep -Fq "game_files='./gamedata/'" "$PORT_TOML"
[ "$(cat config.toml)" = "sentinel='leave alone'" ]
GAMEDIR=relative
if resolve_port_toml; then echo "accepted a relative game root" >&2; exit 1; fi

# A failed atomic write must reach the caller, not launch with partial settings.
portkit_launcher() { return 55; }
if configure_unity_display "$TMP/config.toml" auto auto 75; then
  echo "configure_unity_display swallowed a write failure" >&2
  exit 1
else
  [ "$?" = 55 ]
fi

echo 'Unity configuration contract: PASS'
