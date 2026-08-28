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
# Redirect only the APP Manager child. A selected game must inherit the native
# launcher's descriptors, never APP Manager's log file.
mv -f "$PAM_LOG" "$PAM_LOG.1" 2>/dev/null
PAM_LOG_READY=0
if : > "$PAM_LOG" 2>/dev/null; then
  PAM_LOG_READY=1
fi

pam_run_ui() {
  printf '%s\n' '[PAM] Starting Port App Manager'
  if [ ! -x "$PAM_LOVE" ]; then
    printf '%s\n' '[PAM] APP Manager UI runtime is missing; reinstall APP Manager.' >&2
    return 78
  fi

  export PAM_SOURCE_DIR PAM_APP_ROOT PAM_LAUNCHER
  "$PAM_LOVE" "$PAM_APP_ROOT/love_ui" \
    "${DISPLAY_WIDTH:-960}" "${DISPLAY_HEIGHT:-720}"
}

pam_file_identity() {
  stat -Lc '%d:%i' "$1" 2>/dev/null || stat -f '%i' "$1" 2>/dev/null
}

if [ "$PAM_LOG_READY" = "1" ]; then
  pam_run_ui >> "$PAM_LOG" 2>&1
  PAM_STATUS=$?
else
  pam_run_ui
  PAM_STATUS=$?
fi

# The APP exits with 42 (kit.EXIT_START) when the user picked a game. The
# frontend, web server, input helper and worker process are all gone before this
# shell resumes. Keep this one shell only as a handoff owner, then replace it
# with the exact selected script so no APP Manager process remains alive.
if [ "$PAM_STATUS" = "42" ]; then
  PAM_GAME=""
  PAM_EXPECTED=""
  PAM_GAME_XDG_DATA_HOME=""
  [ -f "$PAM_APP_ROOT/game_to_launch.txt" ] && PAM_GAME="$(cat "$PAM_APP_ROOT/game_to_launch.txt")"
  [ -f "$PAM_APP_ROOT/game_to_launch.fingerprint" ] && PAM_EXPECTED="$(cat "$PAM_APP_ROOT/game_to_launch.fingerprint")"
  [ -f "$PAM_APP_ROOT/game_to_launch.xdg_data_home" ] && PAM_GAME_XDG_DATA_HOME="$(cat "$PAM_APP_ROOT/game_to_launch.xdg_data_home")"
  rm -f "$PAM_APP_ROOT/game_to_launch.txt" \
    "$PAM_APP_ROOT/game_to_launch.fingerprint" \
    "$PAM_APP_ROOT/game_to_launch.xdg_data_home"
  if [ -n "$PAM_GAME" ] && [ -n "$PAM_EXPECTED" ] && [ -f "$PAM_GAME" ] && exec 9<"$PAM_GAME"; then
    PAM_OPEN_SCRIPT=/proc/self/fd/9
    [ -e "$PAM_OPEN_SCRIPT" ] || PAM_OPEN_SCRIPT=/dev/fd/9
    PAM_ACTUAL=$(pam_file_identity "$PAM_OPEN_SCRIPT")
  else
    PAM_ACTUAL=""
  fi
  if [ -n "$PAM_ACTUAL" ] && [ "$PAM_ACTUAL" = "$PAM_EXPECTED" ]; then
    PAM_TARGET=$PAM_GAME
    printf '%s\n' "[PAM] launching game: $PAM_TARGET" >> "$PAM_LOG" 2>/dev/null
    if [ -n "$PAM_GAME_XDG_DATA_HOME" ] && \
        [ -f "$PAM_GAME_XDG_DATA_HOME/PortMaster/control.txt" ]; then
      export XDG_DATA_HOME="$PAM_GAME_XDG_DATA_HOME"
      printf '%s\n' "[PAM] game PortMaster base: $XDG_DATA_HOME" >> "$PAM_LOG" 2>/dev/null
    fi
    # PAM_* is private to this manager. Preserve the native launcher and
    # PortMaster environment, but never leak manager overrides or test knobs
    # into the selected application.
    for PAM_ENV_NAME in $(env | sed -n 's/^\(PAM_[A-Za-z0-9_]*\)=.*/\1/p'); do
      unset "$PAM_ENV_NAME"
    done
    # Execute the already-opened inode while preserving the original path as
    # $0 for normal PortMaster scripts that derive their data directory from it.
    exec /bin/sh -c '. "$1"' "$PAM_TARGET" "$PAM_OPEN_SCRIPT"
  else
    printf '%s\n' '[PAM] EXIT_START without a matching validated game file; exiting.' >&2
    exit 42
  fi
fi
exit "$PAM_STATUS"
