#!/usr/bin/env bash
# INPUT:  D2R NS 源码、共享 UI、PortKit 与端口清单
# OUTPUT: 不含游戏资源或玩家状态的 ports/d2r_ns/dist
# POS:    独立 NS 端口的标准构建入口
set -euo pipefail
PORT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ROOT=$(cd -- "$PORT/../.." && pwd)
STAGE=$(mktemp -d "$PORT/.dist-stage.XXXXXX")
DATA="$STAGE/d2r_ns"
SCRIPT="Je-暗黑破坏神II_NS.sh"
mkdir -p "$DATA/libexec" "$DATA/config"
bash "$ROOT/_kit/assemble.sh" "$PORT/love/launcher.sh.template" "$STAGE/$SCRIPT"
bash "$ROOT/_kit/stage_love_ui.sh" "$DATA/love_ui"
cp "$PORT/love/main.lua" "$DATA/love_ui/main.lua"
bash "$ROOT/_kit/stage_portkit_launcher.sh" "$DATA"
cp "$PORT/src/setup_runtime.py" "$PORT/src/setup_ui_runtime.py" "$PORT/src/run-game.sh" "$DATA/libexec/"
cp "$PORT/src/default-settings.json" "$DATA/config/default-settings.json"
cp "$PORT/LICENSE" "$PORT/README.md" "$DATA/"
cp "$PORT/screenshot.png" "$DATA/screenshot.png"
cp "$PORT/screenshot.png" "$DATA/${SCRIPT%.sh}.png"
python3 "$ROOT/_kit/port_json.py" "$PORT/manifest.json" "$STAGE" d2r_ns
python3 - "$STAGE/port.json" <<'PY'
import json
from pathlib import Path
import sys
p = Path(sys.argv[1]); data = json.loads(p.read_text())
data['attr']['image']['screenshot'] = 'd2r_ns/screenshot.png'
p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
PY
python3 "$ROOT/_kit/build_info.py" "$PORT/manifest.json" "$STAGE"
python3 - "$STAGE" "$PORT/dist" <<'PY'
from pathlib import Path
import shutil
import sys
import uuid
stage, destination = map(Path, sys.argv[1:])
if destination.exists():
    trash = Path.home() / '.Trash'; trash.mkdir(exist_ok=True)
    shutil.move(str(destination), str(trash / ('d2r_ns-dist-' + uuid.uuid4().hex)))
stage.rename(destination)
PY
printf 'D2R NS launcher: %s\n' "$PORT/dist"
