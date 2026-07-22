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
grep -Fq 'exec "$PAM_LOVE"' "$LAUNCHER"
for forbidden in \
  'write_env()' 'apply_plan()' 'pam_core_health()' 'pam_lock_acquire()' \
  'runtime_progress_write()' 'install_portmaster_release()' 'PAM_TEST_'; do
  ! grep -Fq "$forbidden" "$LAUNCHER" || {
    echo "business logic leaked into APP Manager shell: $forbidden" >&2
    exit 1
  }
done

echo "appmanager thin launcher tests: PASS"
