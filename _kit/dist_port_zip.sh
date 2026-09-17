#!/usr/bin/env bash
# INPUT:  端口名、输出目录、dist_port.sh 与 port_zip.py
# OUTPUT: 端口 dist 内容及标准 PortMaster ZIP
# POS:    串联端口构建与 PortMaster 安装包封装
# Build a standard PortMaster ZIP from a port's generated dist directory.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${1:?Usage: _kit/dist_port_zip.sh <port> [output-directory]}"
OUTPUT_DIR="${2:-$ROOT/dist}"
PORT_DIR="$ROOT/ports/$PORT"

bash "$ROOT/_kit/dist_port.sh" "$PORT"
mkdir -p "$OUTPUT_DIR"
python3 "$ROOT/_kit/port_zip.py" \
  "$PORT_DIR/manifest.json" \
  "$PORT_DIR/dist" \
  "$OUTPUT_DIR"
