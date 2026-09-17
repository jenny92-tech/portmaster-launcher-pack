#!/usr/bin/env bash
# INPUT:  目标数据目录、预置 PortKit 二进制、revision 文件与 portkit_launcher_revision.py
# OUTPUT: 目标目录内经源码身份校验的 bin/portkit-launcher
# POS:    在分发前拒绝过期或错误架构的启动辅助程序
# Copy the validated PortKit launcher helper into generated game data.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?Usage: _kit/stage_portkit_launcher.sh <generated-data-dir>}"
RUNTIME="$ROOT/_kit/runtime/portkit-launcher.aarch64"
REVISION_FILE="$ROOT/_kit/portkit-launcher-revision.txt"

PYTHON="${PYTHON:-python3}"
if ! "$PYTHON" -c 'import tomllib' >/dev/null 2>&1; then
  for candidate in python3.13 python3.12 python3.11; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
      PYTHON="$candidate"
      break
    fi
  done
fi
"$PYTHON" -c 'import tomllib' >/dev/null 2>&1 || {
  echo "Python 3.11 or newer is required to stage the PortKit launcher helper." >&2
  exit 69
}

EXPECTED="$("$PYTHON" "$ROOT/_kit/portkit_launcher_revision.py" "$ROOT")"
PACKAGED="$(sed -n '1p' "$REVISION_FILE" 2>/dev/null || true)"

if [ -z "$PACKAGED" ] || [ "$PACKAGED" != "$EXPECTED" ]; then
  echo "stale PortKit launcher helper; run _kit/build_portkit_launcher.sh" >&2
  exit 1
fi
[ -x "$RUNTIME" ] || { echo "missing PortKit launcher helper: $RUNTIME" >&2; exit 1; }
description=$(file "$RUNTIME")
case "$description" in
  *ELF*ARM\ aarch64*static*) ;;
  *) echo "invalid PortKit launcher helper: $description" >&2; exit 1 ;;
esac
grep -aFq "$EXPECTED" "$RUNTIME" || {
  echo "PortKit launcher helper does not match its source revision" >&2
  exit 1
}
mkdir -p "$DEST/bin"
install -m 0755 "$RUNTIME" "$DEST/bin/portkit-launcher"
