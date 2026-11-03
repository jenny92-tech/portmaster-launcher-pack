#!/usr/bin/env bash
# INPUT:  2G 启动器源码、共享构建工具与可选 D2R_NS_2G_ENTRY 正式入口
# OUTPUT: 独立 d2r_ns_2g 数据目录和 Je- 暗黑 2G 入口
# POS:    把已准备安装的路径接入 Pack，不收集其游戏、存档或运行目录
set -euo pipefail
PORT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ROOT=$(cd -- "$PORT/../.." && pwd)
STAGE=$(mktemp -d "$PORT/.dist-stage.XXXXXX")
DATA="$STAGE/d2r_ns_2g"
mkdir -p "$DATA/libexec"
bash "$ROOT/_kit/assemble.sh" "$PORT/src/launcher.sh" "$STAGE/Je-暗黑破坏神II_NS（2G版）.sh"
cp "$PORT/src/launch.py" "$PORT/src/run-game.sh" "$DATA/libexec/"
cp -R "$PORT/src/licenses" "$DATA/licenses"
if [ -n "${D2R_NS_2G_ENTRY:-}" ]; then
    python3 "$PORT/src/scripts/import-entry.py" "$D2R_NS_2G_ENTRY" "$DATA/install-paths.json"
fi
cp "$PORT/LICENSE" "$PORT/README.md" "$DATA/"
cp "$PORT/screenshot.png" "$DATA/screenshot.png"
cp "$PORT/screenshot.png" "$DATA/Je-暗黑破坏神II_NS（2G版）.png"
python3 "$ROOT/_kit/port_json.py" "$PORT/manifest.json" "$STAGE" d2r_ns_2g
python3 - "$STAGE/port.json" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['attr']['image']['screenshot'] = 'd2r_ns_2g/screenshot.png'
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
PY
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
    shutil.move(str(destination), str(trash / ('d2r_ns_2g-dist-' + uuid.uuid4().hex)))
stage.rename(destination)
PY
printf 'D2R 2G launcher: %s\n' "$PORT/dist"
