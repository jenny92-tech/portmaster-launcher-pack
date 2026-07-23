#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="$ROOT/ports/appmanager/src/launcher.sh"

lines=$(wc -l < "$LAUNCHER" | tr -d '[:space:]')
[ "$lines" -le 120 ] || {
  echo "APP Manager launcher is not a thin Rust bootstrap: $lines lines" >&2
  exit 1
}

grep -Fq 'runtime/love.aarch64' "$LAUNCHER"
grep -Fq '"$PAM_LOVE" "$PAM_APP_ROOT/love_ui"' "$LAUNCHER"
! grep -Fq 'exec "$PAM_LOVE"' "$LAUNCHER"
grep -Fq 'exit "$PAM_STATUS"' "$LAUNCHER"
grep -Fq 'log.txt' "$LAUNCHER"
for forbidden in \
  'write_env()' 'apply_plan()' 'pam_core_health()' 'pam_lock_acquire()' \
  'runtime_progress_write()' 'install_portmaster_release()' 'PAM_TEST_'; do
  ! grep -Fq "$forbidden" "$LAUNCHER" || {
    echo "business logic leaked into APP Manager shell: $forbidden" >&2
    exit 1
  }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/source" "$tmp/app"
if PAM_SOURCE_DIR="$tmp/source" PAM_APP_ROOT_OVERRIDE="$tmp/app" \
    PAM_LOVE_BIN_OVERRIDE="$tmp/app/runtime/missing" sh "$LAUNCHER"; then
  echo "launcher unexpectedly accepted a missing UI runtime" >&2
  exit 1
fi
grep -Fq '[PAM] Starting Port App Manager' "$tmp/app/log.txt"
grep -Fq '[PAM] APP Manager UI runtime is missing' "$tmp/app/log.txt"

mkdir -p "$tmp/app/runtime"
cat > "$tmp/app/runtime/love.aarch64" <<'SH'
#!/bin/sh
exit 23
SH
chmod +x "$tmp/app/runtime/love.aarch64"
set +e
PAM_SOURCE_DIR="$tmp/source" PAM_APP_ROOT_OVERRIDE="$tmp/app" \
  sh "$LAUNCHER"
status=$?
set -e
[ "$status" -eq 23 ] || {
  echo "launcher did not preserve LOVE-lite exit status: $status" >&2
  exit 1
}

echo "appmanager thin launcher tests: PASS"
