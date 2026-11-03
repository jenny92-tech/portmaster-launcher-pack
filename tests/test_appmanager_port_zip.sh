#!/usr/bin/env bash
# INPUT:  _kit/dist_port_zip.sh、APP Manager 包源、Python zipfile
# OUTPUT: 标准 Port ZIP 的可重现性、目录安全与入口权限断言结果
# POS:    APP Manager PortMaster ZIP 发行契约回归测试
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash "$ROOT/_kit/dist_port_zip.sh" appmanager "$TMP" >/dev/null
mkdir "$TMP/rebuild"
bash "$ROOT/_kit/dist_port_zip.sh" appmanager "$TMP/rebuild" >/dev/null
cmp "$TMP/jenny92-appmanager.zip" "$TMP/rebuild/jenny92-appmanager.zip"

python3 - "$TMP/jenny92-appmanager.zip" <<'PY'
import json
import stat
import sys
import zipfile
from pathlib import PurePosixPath

path = sys.argv[1]
with zipfile.ZipFile(path) as archive:
    assert archive.testzip() is None
    names = archive.namelist()
    assert len(names) == len(set(names))
    assert "port.json" in names
    assert "APP Manager.sh" in names
    assert "jenny92-appmanager/runtime/love.aarch64" in names
    descriptor = json.loads(archive.read("port.json"))
    assert descriptor["name"] == "jenny92-appmanager.zip"
    assert descriptor["items"] == ["APP Manager.sh", "jenny92-appmanager"]
    assert "screenshot.png" not in names
    assert descriptor["attr"]["image"]["screenshot"] == "jenny92-appmanager/screenshot.png"
    assert "APP Manager.png" not in names
    for artwork in ("jenny92-appmanager/APP Manager.png", descriptor["attr"]["image"]["screenshot"]):
        assert archive.read(artwork).startswith(b"\x89PNG\r\n\x1a\n")
    assert all(".." not in PurePosixPath(name).parts for name in names)
    assert not any(name.startswith("/") for name in names)
    launcher = archive.getinfo("APP Manager.sh")
    assert stat.S_IMODE(launcher.external_attr >> 16) & 0o111
PY

echo "appmanager standard Port ZIP tests: PASS"
