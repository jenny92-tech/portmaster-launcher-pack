#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTACT="QQ 群 1047158975"

grep -Fq "$CONTACT" "$ROOT/_kit/launcher_base.gd" || {
  echo "_kit/launcher_base.gd: missing launcher contact text: $CONTACT" >&2
  exit 1
}

grep -Fq "$CONTACT" "$ROOT/ports/sts2/src/linux/launcher_ui.gd" || {
  echo "ports/sts2/src/linux/launcher_ui.gd: missing launcher contact text: $CONTACT" >&2
  exit 1
}

for manifest in "$ROOT"/ports/*/src/manifest.bootstrap.json; do
  port="$(basename "$(dirname "$(dirname "$manifest")")")"
  python3 - "$manifest" "$port" <<'PY'
import json
import sys

manifest_path, port = sys.argv[1:3]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

for entry in manifest.get("files", []):
    if entry.get("res_path") == "res://launcher_base.gd":
        break
else:
    raise SystemExit(f"{port}: bootstrap manifest does not package launcher_base.gd")
PY
done

python3 - "$ROOT" "$CONTACT" <<'PY'
import sys
from pathlib import Path
from fontTools.ttLib import TTFont

root = Path(sys.argv[1])
contact = sys.argv[2]
fonts = [
    root / "ports/heishenhua/src/assets/launcher_font_zh.ttf",
    root / "ports/hk/src/assets/launcher_font_zh.ttf",
    root / "ports/terraria/src/assets/launcher_font_zh.ttf",
    root / "ports/vampiresurvivors114/src/assets/launcher_font_zh.ttf",
    root / "ports/sts2/src/linux/assets/launcher_font_zh.ttf",
]

for font_path in fonts:
    font = TTFont(str(font_path))
    cmap = {cp for table in font["cmap"].tables for cp in table.cmap.keys()}
    missing = "".join(dict.fromkeys(ch for ch in contact if ord(ch) not in cmap))
    if missing:
        raise SystemExit(f"{font_path.relative_to(root)}: missing glyphs for {missing!r}")
PY
