#!/usr/bin/env bash
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech
#
# Combine a port's modular launcher.sh template + the _kit shared libraries
# into ONE self-contained device script. PortMaster runs a single .sh and the
# handheld has no copy of _kit/, so any `source` of an external file would make
# the launcher fail to start. In the repo we keep the layers separate (clean,
# DRY); at deploy time this stitches them into one file.
#
# Mechanism: the launcher template carries a block
#     #@KIT-BEGIN
#     KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
#     source "$KIT/portmaster_common.sh"
#     source "$KIT/launcher_unity_common.sh"
#     #@KIT-END
# Each `source "$KIT/<file>"` inside it is replaced by that file's contents
# (minus shebang); the KIT= line and the markers are dropped. The result is a
# single script that runs anywhere with no _kit dependency.
#
# Usage:
#   _kit/assemble.sh ports/<port>/src/launcher.sh [output.sh]
#   (default output: ports/<port>/dist/<script from manifest.json>)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?Usage: assemble.sh <ports/<port>/launcher.sh> [out.sh]}"
[ -f "$SRC" ] || { echo "no such launcher: $SRC" >&2; exit 1; }
SRC_DIR="$(cd "$(dirname "$SRC")" && pwd)"
if [ "$(basename "$SRC_DIR")" = "src" ]; then
  PORT_DIR="$(dirname "$SRC_DIR")"
else
  PORT_DIR="$SRC_DIR"
fi
PORT="$(basename "$PORT_DIR")"
SCRIPT_NAME="$(python3 - "$PORT_DIR/manifest.json" "$PORT" <<'PY'
import json
import os
import sys

manifest_path, port = sys.argv[1:3]
script = f"{port}.sh"
if os.path.isfile(manifest_path):
    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
    script = manifest.get("script") or manifest.get("dist", {}).get("script") or script
print(script)
PY
)"
DEFAULT_OUT="$PORT_DIR/dist/$SCRIPT_NAME"
OUT="${2:-$DEFAULT_OUT}"
mkdir -p "$(dirname "$OUT")"

inline_kit() {
  local in_block=0 line f
  while IFS= read -r line; do
    case "$line" in
      *'#@KIT-BEGIN'*)
        in_block=1
        echo "# ─── inlined from _kit/ by assemble.sh — do not edit on device ───"
        continue ;;
      *'#@KIT-END'*)
        in_block=0
        echo "# ─── end inlined _kit ───"
        continue ;;
    esac
    if [ "$in_block" = 1 ]; then
      case "$line" in
        *'source "$KIT/'*)
          f="${line#*\$KIT/}"; f="${f%%\"*}"
          [ -f "$ROOT/_kit/$f" ] || { echo "missing kit file: _kit/$f" >&2; exit 1; }
          echo "# ── _kit/$f ──"
          tail -n +2 "$ROOT/_kit/$f"   # strip shebang, keep the rest
          echo
          ;;
        *) : ;;   # drop the KIT= assignment and anything else in the block
      esac
    else
      printf '%s\n' "$line"
    fi
  done < "$SRC"
}

inline_kit > "$OUT"
chmod +x "$OUT"

# sanity: no unresolved markers / external source left behind, and it parses
if grep -qE '#@KIT|source "\$KIT/' "$OUT"; then
  echo "!! unresolved KIT references remain in $OUT" >&2
  exit 1
fi
bash -n "$OUT" || { echo "!! assembled script has syntax errors: $OUT" >&2; exit 1; }
echo ">>> assembled $PORT -> $OUT ($(wc -l < "$OUT") lines, syntax OK)"
