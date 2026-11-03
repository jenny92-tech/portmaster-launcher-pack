#!/usr/bin/env bash
# INPUT:  余烬灯塔源码、共享组装工具及可选 EMBERWARD_PCK 导出文件
# OUTPUT: ports/emberward/dist 下的标准 PortMaster 布局
# POS:    余烬灯塔启动器与显式游戏导出的统一构建入口
set -euo pipefail
PORT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ROOT=$(cd -- "$PORT/../.." && pwd)
STAGE=$(mktemp -d "$PORT/.dist-stage.XXXXXX")
DATA="$STAGE/emberward"
mkdir -p "$DATA"
bash "$ROOT/_kit/assemble.sh" "$PORT/src/launcher.sh" "$STAGE/Je-余烬灯塔.sh"
if [ -n "${EMBERWARD_PCK:-}" ]; then
    python3 "$PORT/src/scripts/stage-payload.py" "$DATA" "$EMBERWARD_PCK"
else
    python3 "$PORT/src/scripts/stage-payload.py" "$DATA"
fi
cp "$PORT/LICENSE" "$PORT/README.md" "$DATA/"
python3 "$ROOT/_kit/port_json.py" "$PORT/manifest.json" "$STAGE" emberward
python3 "$ROOT/_kit/build_info.py" "$PORT/manifest.json" "$STAGE"
python3 - "$STAGE" "$PORT/dist" <<'PY'
from pathlib import Path
import shutil
import sys
import uuid
stage, destination = map(Path, sys.argv[1:])
if destination.exists():
    trash = Path.home() / '.Trash'
    trash.mkdir(exist_ok=True)
    shutil.move(str(destination), str(trash / ('emberward-dist-' + uuid.uuid4().hex)))
stage.rename(destination)
PY
printf 'Emberward launcher: %s\n' "$PORT/dist"
