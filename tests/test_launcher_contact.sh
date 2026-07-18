#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTACT="QQ 群 1047158975"

grep -Fq "$CONTACT" "$ROOT/_kit/love/kit.lua" || {
  echo "_kit/love/kit.lua: missing launcher contact text: $CONTACT" >&2
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

grep -Fq 'NotoSansSC-Regular.ttf' "$ROOT/_kit/portmaster_common.sh" || {
  echo "shared love launcher no longer provisions the CJK font" >&2
  exit 1
}
