#!/usr/bin/env bash
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
