#!/usr/bin/env bash
# INPUT:  GDRE Tools、恢复项目目录、输出 PCK 路径和可选参数
# OUTPUT: 由恢复项目创建的新 PCK
# POS:    为可完整重建的 Godot 项目提供直接重打包入口
# Build a new pck from a (patched + re-imported) recovered project using
# GDRE Tools --pck-create. Output goes next to the input pck or to the given
# path.
#
# Usage: repack.sh <recovered_dir> <out.pck> [--pck-version=2] [--pck-engine-version=4.5.1]

set -euo pipefail

PROJECT_DIR="${1:?usage: repack.sh <recovered_dir> <out.pck> [extra GDRE args]}"
OUT_PCK="${2:?usage: repack.sh <recovered_dir> <out.pck> [extra GDRE args]}"
shift 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -s)" in
  Darwin) GDRE="$SCRIPT_DIR/bin/Godot RE Tools.app/Contents/MacOS/Godot RE Tools" ;;
  Linux)  GDRE="$SCRIPT_DIR/bin/gdre_tools" ;;
  *)      echo "Unsupported OS"; exit 1 ;;
esac

DEFAULT_ARGS=(--pck-version=2 --pck-engine-version=4.5.1)
if [ $# -eq 0 ]; then set -- "${DEFAULT_ARGS[@]}"; fi

"$GDRE" --headless --pck-create="$PROJECT_DIR" --output="$OUT_PCK" "$@" 2>&1 | tail -20

echo "==> Output: $(ls -lh "$OUT_PCK" 2>/dev/null)"
