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
grep -Fq 'game_to_launch.xdg_data_home' "$LAUNCHER"
grep -Fq 'export XDG_DATA_HOME="$PAM_GAME_XDG_DATA_HOME"' "$LAUNCHER"
grep -Fq "sed -n 's/^\\(PAM_[A-Za-z0-9_]*\\)=.*/\\1/p'" "$LAUNCHER"
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

# A launch handoff must fully drop the APP Manager process environment and log
# redirection while preserving the selected script's real path as $0.
mkdir -p "$tmp/handoff app/runtime" "$tmp/selected games"
cat > "$tmp/handoff app/runtime/love.aarch64" <<'SH'
#!/bin/sh
target="$TEST_TARGET_SCRIPT"
printf '%s\n' "$target" > "$PAM_APP_ROOT/game_to_launch.txt"
python3 -c 'import os, sys; value=os.stat(sys.argv[1]); print(value.st_ino if sys.platform == "darwin" else f"{value.st_dev}:{value.st_ino}")' \
  "$target" > "$PAM_APP_ROOT/game_to_launch.fingerprint"
exit 42
SH
chmod +x "$tmp/handoff app/runtime/love.aarch64"
cat > "$tmp/selected games/Exact Game.sh" <<'SH'
if env | grep -q '^PAM_'; then
  env | grep '^PAM_' > "$TEST_CAPTURE_DIR/leaked-environment"
  exit 91
fi
printf '%s\n' "$0" > "$TEST_CAPTURE_DIR/invoked-as"
printf '%s\n' 'TARGET_STDOUT'
SH
chmod +x "$tmp/selected games/Exact Game.sh"
TEST_CAPTURE_DIR="$tmp" \
TEST_TARGET_SCRIPT="$tmp/selected games/Exact Game.sh" \
PAM_SOURCE_DIR="$tmp/source" \
PAM_APP_ROOT_OVERRIDE="$tmp/handoff app" \
PAM_STATE_DIR_OVERRIDE="$tmp/private-state" \
PAM_WEB_TEST_CODE=123456 \
  sh "$LAUNCHER" > "$tmp/target.stdout" 2> "$tmp/target.stderr" || {
    status=$?
    cat "$tmp/handoff app/log.txt" >&2
    cat "$tmp/target.stderr" >&2
    echo "launcher handoff failed with status $status" >&2
    exit "$status"
  }
[ ! -e "$tmp/leaked-environment" ]
[ "$(cat "$tmp/invoked-as")" = "$tmp/selected games/Exact Game.sh" ]
grep -Fxq 'TARGET_STDOUT' "$tmp/target.stdout"
! grep -Fq 'TARGET_STDOUT' "$tmp/handoff app/log.txt"
[ ! -e "$tmp/handoff app/game_to_launch.txt" ]
[ ! -e "$tmp/handoff app/game_to_launch.fingerprint" ]

echo "appmanager thin launcher tests: PASS"
