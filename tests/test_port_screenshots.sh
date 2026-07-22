#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for port in appmanager heishenhua hk terraria sts2 vampiresurvivors114; do
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

for name in manifest.get("portmaster", {}).get("image", {}).get("names", []):
    if not isinstance(name, str) or not name:
        raise SystemExit(f"{manifest_path}: invalid portmaster.image.names entry")
PY
done
