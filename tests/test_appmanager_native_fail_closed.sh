#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/app/bin" "$TMP/source"
cat > "$TMP/app/bin/broken-portkit" <<'SH'
#!/bin/sh
exit 2
SH
chmod +x "$TMP/app/bin/broken-portkit"

if env PAM_TOOL_MODE=system \
  PAM_PORTKIT_BIN_OVERRIDE="$TMP/app/bin/broken-portkit" \
  PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check \
  >"$TMP/out" 2>"$TMP/err"; then
  echo "production launcher silently fell back after native resolver failure" >&2
  exit 1
fi
grep -Fq 'native device profile failed' "$TMP/err"

echo "appmanager native fail-closed tests: PASS"
