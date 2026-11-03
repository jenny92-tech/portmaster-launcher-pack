#!/usr/bin/env bash
# INPUT:  端口名、输出目录、dist_port.sh 及标准或端口专用 ZIP 生成器
# OUTPUT: 端口 dist 内容及标准或端口专用 ZIP
# POS:    串联端口构建与封装，专用 SD 卡布局由端口自己的生成器维护
# Package a port's generated dist directory with its selected ZIP layout.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${1:?Usage: _kit/dist_port_zip.sh <port> [output-directory]}"
OUTPUT_DIR="${2:-$ROOT/dist}"
PORT_DIR="$ROOT/ports/$PORT"

bash "$ROOT/_kit/dist_port.sh" "$PORT"
mkdir -p "$OUTPUT_DIR"
if [ -f "$PORT_DIR/src/scripts/dist-zip.py" ]; then
  exec python3 "$PORT_DIR/src/scripts/dist-zip.py" --dist "$PORT_DIR/dist" --output "$OUTPUT_DIR/$PORT.zip"
fi
python3 "$ROOT/_kit/port_zip.py" \
  "$PORT_DIR/manifest.json" \
  "$PORT_DIR/dist" \
  "$OUTPUT_DIR"
