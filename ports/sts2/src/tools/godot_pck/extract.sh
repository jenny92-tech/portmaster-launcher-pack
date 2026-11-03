#!/usr/bin/env bash
# INPUT:  GDRE Tools、输入 PCK 与可选输出目录
# OUTPUT: 恢复出的 Godot 源项目目录
# POS:    为资源压缩与覆盖补丁准备 PCK 恢复工作树
# Recover a godot 4.x pck back to its source tree (PNG + .import + .gd etc.).
# Usage: extract.sh <input.pck> [<output_dir>]
#   defaults output_dir to ./work/$(basename input .pck)_recovered/

set -euo pipefail

PCK="${1:?usage: extract.sh <input.pck> [output_dir]}"
OUT="${2:-./work/$(basename "$PCK" .pck)_recovered}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -s)" in
  Darwin) GDRE="$SCRIPT_DIR/bin/Godot RE Tools.app/Contents/MacOS/Godot RE Tools" ;;
  Linux)  GDRE="$SCRIPT_DIR/bin/gdre_tools" ;;
  *)      echo "Unsupported OS"; exit 1 ;;
esac

if [ ! -x "$GDRE" ]; then
  echo "GDRE Tools missing at $GDRE — see $SCRIPT_DIR/bin/README.md"
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

echo "==> Recovering $PCK → $OUT"
"$GDRE" --headless --recover="$PCK" --output="$OUT"
echo "==> Done. Inspect with: ls -la $OUT"
