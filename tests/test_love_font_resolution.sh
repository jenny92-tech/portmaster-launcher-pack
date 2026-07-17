#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

controlfolder="$TMP/PortMaster"
PM_RESOURCE_DIR="$controlfolder/resources"
ESUDO=""
LOG_PREFIX="[font-test]"
UI_DIR="$TMP/love_ui"
mkdir -p "$PM_RESOURCE_DIR" "$controlfolder/pylibs/resources" "$UI_DIR"

source "$ROOT/_kit/portmaster_common.sh"

# The canonical PortMaster resource wins over both compatibility and stale
# per-launcher copies. Shell resolution keeps the old copy until Kit proves it
# can load the shared file, so a failed direct read still has a safe fallback.
truncate -s 1000001 "$PM_RESOURCE_DIR/NotoSansSC-Regular.ttf"
truncate -s 1000001 "$controlfolder/pylibs/resources/NotoSansSC-Regular.ttf"
truncate -s 1000001 "$UI_DIR/font.ttf"
_love_provide_font "$UI_DIR"
[ "$LOVE_FONT_PATH" = "$PM_RESOURCE_DIR/NotoSansSC-Regular.ttf" ]
[ -e "$UI_DIR/font.ttf" ]

# Older PortMaster layouts remain a valid direct source when the canonical
# resource directory has not been populated.
rm -f "$PM_RESOURCE_DIR/NotoSansSC-Regular.ttf"
truncate -s 1000001 "$UI_DIR/font.ttf"
_love_provide_font "$UI_DIR"
[ "$LOVE_FONT_PATH" = "$controlfolder/pylibs/resources/NotoSansSC-Regular.ttf" ]
[ -e "$UI_DIR/font.ttf" ]

# A local copy is only the final fallback when no validated shared font or
# repair source exists.
rm -f "$controlfolder/pylibs/resources/NotoSansSC-Regular.ttf"
truncate -s 1000001 "$UI_DIR/font.ttf"
_love_provide_font "$UI_DIR"
[ "$LOVE_FONT_PATH" = "$UI_DIR/font.ttf" ]

echo "love font resolution tests: PASS"
