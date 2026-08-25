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

# Standard love-port handoff: the APP exits with 42 (kit.EXIT_START) when the
# user picked a game to launch. The launcher script owns the shell that the
# frontend called, so it execs the game *after* the APP has fully closed --
# same pattern as every PortMaster LÖVE game. The APP is gone (window and
# process), nothing fights the game for the display, and when the game exits
# the whole script returns and the frontend restores its UI normally.
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
    PAM_ACTUAL=$(stat -Lc '%d:%i' /proc/self/fd/9 2>/dev/null)
  else
    PAM_ACTUAL=""
  fi
  if [ -n "$PAM_ACTUAL" ] && [ "$PAM_ACTUAL" = "$PAM_EXPECTED" ]; then
    printf '%s\n' "[PAM] launching game: $PAM_GAME"
    if [ -n "$PAM_GAME_XDG_DATA_HOME" ] && \
        [ -f "$PAM_GAME_XDG_DATA_HOME/PortMaster/control.txt" ]; then
      export XDG_DATA_HOME="$PAM_GAME_XDG_DATA_HOME"
      printf '%s\n' "[PAM] game PortMaster base: $XDG_DATA_HOME"
    fi
    # Execute the already-opened inode while preserving the original path as
    # $0 for normal PortMaster scripts that derive their data directory from it.
    exec /bin/sh -c '. /proc/self/fd/9' "$PAM_GAME"
  else
    printf '%s\n' '[PAM] EXIT_START without a matching validated game file; exiting.' >&2
    exit 42
  fi
fi
exit "$PAM_STATUS"
