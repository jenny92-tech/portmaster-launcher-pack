#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTACT="QQ 群 1047158975"

grep -Fq "$CONTACT" "$ROOT/_kit/love/kit.lua" || {
  echo "_kit/love/kit.lua: missing launcher contact text: $CONTACT" >&2
  exit 1
}

grep -Fq "$CONTACT" "$ROOT/_kit/launcher_base.gd" || {
  echo "_kit/launcher_base.gd: missing legacy launcher contact text: $CONTACT" >&2
  exit 1
}

for main in "$ROOT"/ports/*/love/main.lua; do
  case "$main" in
    */ports/appmanager/*) required='require("kit")' ;;
    *) required='require("launcher")' ;;
  esac
  grep -Fq "$required" "$main" || {
    echo "${main#$ROOT/}: does not load the shared LÖVE layer" >&2
    exit 1
  }
done

for manifest in "$ROOT"/ports/*/src/manifest.bootstrap.json; do
  [ -f "$manifest" ] || continue
  python3 - "$manifest" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
if not any(entry.get("res_path") == "res://launcher_base.gd" for entry in manifest.get("files", [])):
    raise SystemExit(f"{sys.argv[1]}: bootstrap manifest does not package launcher_base.gd")
PY
done

grep -Fq 'NotoSansSC-Regular.ttf' "$ROOT/_kit/portmaster_common.sh" || {
  echo "shared love launcher no longer provisions the CJK font" >&2
  exit 1
}
