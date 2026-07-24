#!/bin/sh
# PORTMASTER: jenny92-appmanager, APP Manager.sh
# Thin bootstrap only. The shell remains as the frontend-owned parent while
# LOVE-lite runs as its child, matching ordinary PortMaster LÖVE launchers.
# Device policy and APP behavior live in config.json and linked Rust crates.

PAM_SCRIPT_DIR=$0
case "$PAM_SCRIPT_DIR" in
  */*) PAM_SCRIPT_DIR=${PAM_SCRIPT_DIR%/*} ;;
  *) PAM_SCRIPT_DIR=. ;;
esac
PAM_DIR=${PAM_SOURCE_DIR:-$(CDPATH= cd -- "$PAM_SCRIPT_DIR" && pwd)}
PAM_APP_ROOT=${PAM_APP_ROOT_OVERRIDE:-$PAM_DIR/jenny92-appmanager}
PAM_LAUNCHER=${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_DIR/APP Manager.sh}
PAM_LOVE=${PAM_LOVE_BIN_OVERRIDE:-$PAM_APP_ROOT/runtime/love.aarch64}
PAM_LOG=$PAM_APP_ROOT/log.txt

# One local diagnostic log per launch, with the previous launch kept as
# log.txt.1: the newest failure must survive one restart to be diagnosable.
# LOVE-lite and its embedded Rust service inherit these descriptors, so
# initialization failures and runtime errors land in the same file without a
# shell-side logging process.
mv -f "$PAM_LOG" "$PAM_LOG.1" 2>/dev/null
if : > "$PAM_LOG" 2>/dev/null; then
  exec >> "$PAM_LOG" 2>&1
fi
printf '%s\n' '[PAM] Starting Port App Manager'

if [ ! -x "$PAM_LOVE" ]; then
  printf '%s\n' '[PAM] APP Manager UI runtime is missing; reinstall APP Manager.' >&2
  exit 78
fi

export PAM_SOURCE_DIR PAM_APP_ROOT PAM_LAUNCHER
"$PAM_LOVE" "$PAM_APP_ROOT/love_ui" \
  "${DISPLAY_WIDTH:-960}" "${DISPLAY_HEIGHT:-720}"
PAM_STATUS=$?
exit "$PAM_STATUS"
