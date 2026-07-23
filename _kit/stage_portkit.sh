#!/usr/bin/env bash
# Copy the validated portable PortKit into one generated game-data directory.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?Usage: _kit/stage_portkit.sh <generated-data-dir>}"
RUNTIME="$ROOT/_kit/runtime/portkit.aarch64"
REVISION_FILE="$ROOT/_kit/portkit-revision.txt"
EXPECTED="$(python3 "$ROOT/_kit/portkit_revision.py" "$ROOT")"
PACKAGED="$(sed -n '1p' "$REVISION_FILE" 2>/dev/null || true)"

if [ -z "$PACKAGED" ] || [ "$PACKAGED" != "$EXPECTED" ]; then
  echo "stale portable PortKit; run _kit/build_portkit.sh" >&2
  exit 1
fi
[ -x "$RUNTIME" ] || { echo "missing portable PortKit: $RUNTIME" >&2; exit 1; }
description=$(file "$RUNTIME")
case "$description" in
  *ELF*ARM\ aarch64*static*) ;;
  *) echo "invalid portable PortKit: $description" >&2; exit 1 ;;
esac
grep -aFq "$EXPECTED" "$RUNTIME" || {
  echo "portable PortKit does not match its source revision" >&2
  exit 1
}
mkdir -p "$DEST/bin"
install -m 0755 "$RUNTIME" "$DEST/bin/portkit"
