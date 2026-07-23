#!/usr/bin/env bash
# Copy the validated PortKit launcher helper into generated game data.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?Usage: _kit/stage_portkit_launcher.sh <generated-data-dir>}"
RUNTIME="$ROOT/_kit/runtime/portkit-launcher.aarch64"
REVISION_FILE="$ROOT/_kit/portkit-launcher-revision.txt"
EXPECTED="$(python3 "$ROOT/_kit/portkit_launcher_revision.py" "$ROOT")"
PACKAGED="$(sed -n '1p' "$REVISION_FILE" 2>/dev/null || true)"

if [ -z "$PACKAGED" ] || [ "$PACKAGED" != "$EXPECTED" ]; then
  echo "stale PortKit launcher helper; run _kit/build_portkit_launcher.sh" >&2
  exit 1
fi
[ -x "$RUNTIME" ] || { echo "missing PortKit launcher helper: $RUNTIME" >&2; exit 1; }
description=$(file "$RUNTIME")
case "$description" in
  *ELF*ARM\ aarch64*static*) ;;
  *) echo "invalid PortKit launcher helper: $description" >&2; exit 1 ;;
esac
grep -aFq "$EXPECTED" "$RUNTIME" || {
  echo "PortKit launcher helper does not match its source revision" >&2
  exit 1
}
mkdir -p "$DEST/bin"
install -m 0755 "$RUNTIME" "$DEST/bin/portkit-launcher"
