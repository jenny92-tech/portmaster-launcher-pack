#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash "$ROOT/_kit/dist_trimui_app.sh" appmanager "$TMP" >/dev/null
bash "$ROOT/_kit/dist_trimui_app.sh" terraria "$TMP" >/dev/null

python3 - "$TMP" <<'PY'
import json
import stat
import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1])

with zipfile.ZipFile(root / "[TrimUI App] APP Manager.zip") as archive:
    assert archive.testzip() is None
    names = set(archive.namelist())
    prefix = "jenny92-appmanager/"
    assert {name.split("/", 1)[0] for name in names} == {"jenny92-appmanager"}
    for required in (
        "config.json", "icon.png", "launch.sh", "APP Manager.sh",
        "jenny92-appmanager/config/config.json",
        "jenny92-appmanager/config/platforms/miniloong.json",
        "jenny92-appmanager/love_ui/main.lua", "jenny92-appmanager/runtime/love.aarch64",
    ):
        assert prefix + required in names, required
    config = json.loads(archive.read(prefix + "config.json"))
    assert config["package"] == "com.jenny92.portappmanager"
    assert config["launch"] == "launch.sh"
    launcher = archive.read(prefix + "launch.sh").decode()
    assert 'export PAM_SOURCE_DIR="$APP_DIR"' in launcher
    assert "export PAM_SCRIPTS_DIR_OVERRIDE=/mnt/SDCARD/Roms/PORTS" in launcher
    assert 'exec "$APP_DIR/APP Manager.sh" "$@"' in launcher
    for executable in (prefix + "launch.sh", prefix + "APP Manager.sh"):
        mode = archive.getinfo(executable).external_attr >> 16
        assert mode & stat.S_IXUSR, executable
    assert not any(
        part.startswith("._") or part in {".DS_Store", "__MACOSX", "state", "trash"}
        for name in names for part in name.rstrip("/").split("/")
    )

with zipfile.ZipFile(root / "[TrimUI App] Terraria.zip") as archive:
    assert archive.testzip() is None
    names = set(archive.namelist())
    prefix = "terraria/"
    assert prefix + "T_泰拉瑞亚[中].sh" in names
    assert prefix + "launch.sh" in names
    assert prefix + "config.json" in names
    assert prefix + "icon.png" in names
    assert not any(name.startswith(prefix + "love_ui/") for name in names)
    launcher = archive.read(prefix + "launch.sh").decode()
    assert 'exec "$APP_DIR/T_泰拉瑞亚[中].sh" "$@"' in launcher
PY

# A descendant symlink must never make the packager copy files from outside a
# declared dist tree into a release archive.
mkdir -p "$TMP/symlink-port" "$TMP/symlink-dist/payload" "$TMP/symlink-out"
printf '#!/bin/sh\n' > "$TMP/symlink-dist/Test.sh"
printf 'secret\n' > "$TMP/secret.txt"
ln -s "$TMP/secret.txt" "$TMP/symlink-dist/payload/leak.txt"
cp "$ROOT/ports/appmanager/trimui-app/icon.png" "$TMP/symlink-port/icon.png"
cat > "$TMP/symlink-port/manifest.json" <<'JSON'
{"name":"test","title":"Test","script":"Test.sh","trimui_app":{"folder":"test","archive":"Test","icon":"icon.png","include":["Test.sh","payload"]}}
JSON
if python3 "$ROOT/_kit/trimui_app.py" \
  "$TMP/symlink-port/manifest.json" "$TMP/symlink-dist" "$TMP/symlink-port" "$TMP/symlink-out" \
  >/dev/null 2>&1; then
  echo "trimui packager followed a descendant symlink" >&2
  exit 1
fi

# The selected top-level include itself must not be a symlink either.
mkdir -p "$TMP/top-symlink-port" "$TMP/top-symlink-dist/real" "$TMP/top-symlink-out"
printf '#!/bin/sh\n' > "$TMP/top-symlink-dist/Test.sh"
printf 'payload\n' > "$TMP/top-symlink-dist/real/file.txt"
ln -s real "$TMP/top-symlink-dist/payload"
cp "$ROOT/ports/appmanager/trimui-app/icon.png" "$TMP/top-symlink-port/icon.png"
cat > "$TMP/top-symlink-port/manifest.json" <<'JSON'
{"name":"test","title":"Test","script":"Test.sh","trimui_app":{"folder":"test","archive":"Test","icon":"icon.png","include":["Test.sh","payload"]}}
JSON
if python3 "$ROOT/_kit/trimui_app.py" \
  "$TMP/top-symlink-port/manifest.json" "$TMP/top-symlink-dist" "$TMP/top-symlink-port" "$TMP/top-symlink-out" \
  >/dev/null 2>&1; then
  echo "trimui packager followed a top-level symlink" >&2
  exit 1
fi

echo "trimui app packager tests: PASS"
