#!/bin/sh
# PORTMASTER: jenny92-appmanager, APP Manager.sh
# Thin bootstrap only. LOVE-lite is the Rust main process; device policy and
# APP behavior live in config.json and linked Rust crates.

PAM_SCRIPT_DIR=$0
case "$PAM_SCRIPT_DIR" in
  */*) PAM_SCRIPT_DIR=${PAM_SCRIPT_DIR%/*} ;;
  *) PAM_SCRIPT_DIR=. ;;
esac
PAM_DIR=${PAM_SOURCE_DIR:-$(CDPATH= cd -- "$PAM_SCRIPT_DIR" && pwd)}
PAM_APP_ROOT=${PAM_APP_ROOT_OVERRIDE:-$PAM_DIR/jenny92-appmanager}
PAM_LAUNCHER=${PAM_NATIVE_LAUNCHER_OVERRIDE:-$PAM_DIR/APP Manager.sh}
PAM_LOVE=${PAM_LOVE_BIN_OVERRIDE:-$PAM_APP_ROOT/runtime/love.aarch64}

if [ ! -x "$PAM_LOVE" ]; then
  printf '%s\n' '[PAM] APP Manager UI runtime is missing; reinstall APP Manager.' >&2
  exit 78
fi

export PAM_SOURCE_DIR PAM_APP_ROOT PAM_LAUNCHER
exec "$PAM_LOVE" "$PAM_APP_ROOT/love_ui" \
  "${DISPLAY_WIDTH:-960}" "${DISPLAY_HEIGHT:-720}"
