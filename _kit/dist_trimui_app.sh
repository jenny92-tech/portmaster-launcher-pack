#!/usr/bin/env bash
# Build a TrimUI MainUI application archive from an existing port manifest.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${1:?Usage: _kit/dist_trimui_app.sh <port> [output-directory]}"
OUTPUT_DIR="${2:-$ROOT/dist}"
PORT_DIR="$ROOT/ports/$PORT"

[ -f "$PORT_DIR/manifest.json" ] || {
  echo "missing manifest: $PORT_DIR/manifest.json" >&2
  exit 1
}

bash "$ROOT/_kit/dist_port.sh" "$PORT"
mkdir -p "$OUTPUT_DIR"
python3 "$ROOT/_kit/trimui_app.py" \
  "$PORT_DIR/manifest.json" \
  "$PORT_DIR/dist" \
  "$PORT_DIR" \
  "$OUTPUT_DIR"
