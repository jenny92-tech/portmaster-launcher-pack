#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/_kit/runtime/portkit-launcher.aarch64"
EXPECTED="$(python3 "$ROOT/_kit/portkit_launcher_revision.py" "$ROOT")"
PACKAGED="$(sed -n '1p' "$ROOT/_kit/portkit-launcher-revision.txt")"

[ "$EXPECTED" = "$PACKAGED" ]
[ -x "$RUNTIME" ]
description=$(file "$RUNTIME")
case "$description" in
  *ELF*ARM\ aarch64*static*) ;;
  *) echo "unexpected portable PortKit: $description" >&2; exit 1 ;;
esac
grep -aFq "$EXPECTED" "$RUNTIME"
[ "$(wc -c < "$RUNTIME")" -lt 1572864 ]

bash "$ROOT/_kit/dist_port.sh" hk >/dev/null
[ -x "$ROOT/ports/hk/dist/bin/portkit-launcher" ]
cmp "$RUNTIME" "$ROOT/ports/hk/dist/bin/portkit-launcher"

bash "$ROOT/_kit/dist_port.sh" appmanager >/dev/null
[ ! -e "$ROOT/ports/appmanager/dist/jenny92-appmanager/bin/portkit-launcher" ]

echo "portable PortKit launcher tool tests: PASS"
