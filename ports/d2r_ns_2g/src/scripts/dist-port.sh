#!/usr/bin/env bash
# INPUT:  2G 启动源码、共享构建工具和可选的入口或安装路径清单
# OUTPUT: 独立 d2r_ns_2g 数据目录和 Je- 暗黑 2G 入口
# POS:    把已准备安装的路径接入 Pack，不收集其游戏、存档或运行目录
set -euo pipefail
PORT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ROOT=$(cd -- "$PORT/../.." && pwd)
STAGE="$ROOT/.scratch/d2r-ns/stage"
if [ -n "${D2R_NS_2G_ENTRY:-}" ] && [ -n "${D2R_NS_2G_PATHS:-}" ]; then
    echo 'Specify either D2R_NS_2G_ENTRY or D2R_NS_2G_PATHS.' >&2
    exit 2
fi
mkdir -p "$(dirname -- "$STAGE")"
mkdir "$STAGE" || { echo "staging directory is in use: $STAGE" >&2; exit 1; }
STAGE_ID=$(python3 - "$STAGE" <<'PY'
from pathlib import Path
import sys
identity = Path(sys.argv[1]).stat()
print(f'{identity.st_dev}:{identity.st_ino}')
PY
)
cleanup_stage() {
    python3 - "$STAGE" "$STAGE_ID" <<'PY'
from pathlib import Path
import shutil
import sys
stage = Path(sys.argv[1])
try:
    identity = stage.lstat()
except FileNotFoundError:
    pass
else:
    if f'{identity.st_dev}:{identity.st_ino}' == sys.argv[2]:
        shutil.rmtree(stage)
PY
}
trap cleanup_stage EXIT
DATA="$STAGE/d2r_ns_2g"
mkdir -p "$DATA/libexec"
bash "$ROOT/_kit/assemble.sh" "$PORT/src/launcher.sh" "$STAGE/Je-暗黑破坏神II_NS（2G版）.sh"
cp "$PORT/src/launch.py" "$PORT/src/run-game.sh" "$DATA/libexec/"
cp -R "$PORT/src/licenses" "$DATA/licenses"
if [ -n "${D2R_NS_2G_ENTRY:-}" ]; then
    python3 "$PORT/src/scripts/import-entry.py" "$D2R_NS_2G_ENTRY" "$DATA/install-paths.json"
elif [ -n "${D2R_NS_2G_PATHS:-}" ]; then
    python3 "$PORT/src/scripts/import-entry.py" --paths "$D2R_NS_2G_PATHS" "$DATA/install-paths.json"
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
