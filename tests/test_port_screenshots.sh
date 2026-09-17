#!/usr/bin/env bash
# INPUT:  各端口 manifest.json、截图文件、Python json/os
# OUTPUT: 截图声明、PNG 文件签名和图片命名字段断言结果
# POS:    PortMaster 包预览资源与清单一致性检查
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for port in appmanager heishenhua hk recorder silksong sunkendragon terraria sts2 vampiresurvivors114; do
  manifest="$ROOT/ports/$port/manifest.json"
  python3 - "$ROOT" "$port" "$manifest" <<'PY'
import json
import os
import sys

root, port, manifest_path = sys.argv[1:4]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

shot = manifest.get("portmaster", {}).get("image", {}).get("screenshot")
if not shot:
    raise SystemExit(f"{manifest_path}: missing portmaster.image.screenshot")

path = os.path.join(root, "ports", port, shot)
if not os.path.isfile(path):
    raise SystemExit(f"{manifest_path}: screenshot file not found: {shot}")

with open(path, "rb") as fh:
    magic = fh.read(8)
if magic != b"\x89PNG\r\n\x1a\n":
    raise SystemExit(f"{manifest_path}: screenshot is not a PNG: {shot}")

if port == "silksong":
    items = manifest["portmaster"]["items"]
    for image in ("screenshot.png", os.path.splitext(manifest["script"])[0] + ".png"):
        if image not in items:
            raise SystemExit(f"{manifest_path}: image missing from ZIP items: {image}")

for name in manifest.get("portmaster", {}).get("image", {}).get("names", []):
    if not isinstance(name, str) or not name:
        raise SystemExit(f"{manifest_path}: invalid portmaster.image.names entry")
PY
done
