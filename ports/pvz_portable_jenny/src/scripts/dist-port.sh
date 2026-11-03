#!/usr/bin/env bash
# INPUT:  PvZ 启动器、共享组装工具与可选显式 PVZ_PORTABLE_RUNTIME 目录
# OUTPUT: 无游戏资源和玩家档案的标准 PvZ PortMaster 目录
# POS:    维护版 PvZ 的固定文件清单构建入口
set -euo pipefail
PORT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ROOT=$(cd -- "$PORT/../.." && pwd)
STAGE=$(mktemp -d "$PORT/.dist-stage.XXXXXX")
DATA="$STAGE/pvz_portable_jenny"
mkdir -p "$DATA"
cp "$PORT/LICENSE" "$PORT/README.md" "$PORT/src/PvzPortable.gptk" "$DATA/"
# The device launcher has bash-only cleanup; preserve its Bash re-exec guard.
cp "$PORT/src/launcher.sh" "$STAGE/Je-植物大战僵尸年度版[中].sh"
chmod 755 "$STAGE/Je-植物大战僵尸年度版[中].sh"
python3 - "$DATA" "${PVZ_PORTABLE_RUNTIME:-}" <<'PY'
from pathlib import Path
import shutil
import sys
out, value = sys.argv[1:]
if value:
    root = Path(value)
    for name in ['pvz_portable.aarch64', 'libs.aarch64', 'gconv', 'licenses']:
        source = root / name
        if source.is_symlink() or not source.exists():
            raise ValueError('missing regular runtime input: ' + name)
        target = Path(out) / name
        if source.is_dir():
            if any(p.is_symlink() for p in source.rglob('*')):
                raise ValueError('linked runtime input: ' + name)
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)
PY
python3 "$ROOT/_kit/port_json.py" "$PORT/manifest.json" "$STAGE" pvz_portable_jenny
python3 "$ROOT/_kit/build_info.py" "$PORT/manifest.json" "$STAGE"
# A regular source build remains resource-free; the device export builder owns
# the additional portable execution adapter and final 7z identity.
bash -n "$STAGE/Je-植物大战僵尸年度版[中].sh"
python3 - "$STAGE" "$PORT/dist" <<'PY'
from pathlib import Path
import subprocess
import sys
stage, destination = map(Path, sys.argv[1:])
if destination.exists():
    subprocess.run(['/usr/bin/trash', str(destination)], check=True)
stage.rename(destination)
PY
