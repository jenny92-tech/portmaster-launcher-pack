#!/bin/sh
# INPUT:  PAM_* 路径配置、LOVE-lite runtime、原生服务写出的游戏交接文件
# OUTPUT: APP Manager 子进程、轮转日志与选定启动脚本的 exec 交接
# POS:    APP Manager 保留前端父进程关系的轻量启动入口
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
  PAM_GAME_KIND=""
  PAM_GAME_XDG_DATA_HOME=""
  [ -f "$PAM_APP_ROOT/game_to_launch.txt" ] && PAM_GAME="$(cat "$PAM_APP_ROOT/game_to_launch.txt")"
  [ -f "$PAM_APP_ROOT/game_to_launch.kind" ] && PAM_GAME_KIND="$(cat "$PAM_APP_ROOT/game_to_launch.kind")"
  [ -f "$PAM_APP_ROOT/game_to_launch.xdg_data_home" ] && PAM_GAME_XDG_DATA_HOME="$(cat "$PAM_APP_ROOT/game_to_launch.xdg_data_home")"
  rm -f "$PAM_APP_ROOT/game_to_launch.txt" \
    "$PAM_APP_ROOT/game_to_launch.kind" \
    "$PAM_APP_ROOT/game_to_launch.fingerprint" \
    "$PAM_APP_ROOT/game_to_launch.xdg_data_home"
  if [ -n "$PAM_GAME" ] && [ -f "$PAM_GAME" ] && \
      { [ "$PAM_GAME_KIND" = "port" ] || [ "$PAM_GAME_KIND" = "trimui_app" ]; }; then
    PAM_TARGET=$PAM_GAME
    printf '%s\n' "[PAM] launching $PAM_GAME_KIND: $PAM_TARGET" >> "$PAM_LOG" 2>/dev/null
    if [ "$PAM_GAME_KIND" = "port" ] && [ -n "$PAM_GAME_XDG_DATA_HOME" ] && \
        [ -f "$PAM_GAME_XDG_DATA_HOME/PortMaster/control.txt" ]; then
      export XDG_DATA_HOME="$PAM_GAME_XDG_DATA_HOME"
      printf '%s\n' "[PAM] PortMaster base: $XDG_DATA_HOME" >> "$PAM_LOG" 2>/dev/null
    elif [ "$PAM_GAME_KIND" = "trimui_app" ]; then
      unset XDG_DATA_HOME
    fi
    # PAM_* is private to this manager. Preserve the native launcher and
    # PortMaster environment, but never leak manager overrides or test knobs
    # into the selected application.
    for PAM_ENV_NAME in $(env | sed -n 's/^\(PAM_[A-Za-z0-9_]*\)=.*/\1/p'); do
      unset "$PAM_ENV_NAME"
    done
    PAM_TARGET_DIR=${PAM_TARGET%/*}
    [ "$PAM_TARGET_DIR" = "$PAM_TARGET" ] && PAM_TARGET_DIR=.
    cd "$PAM_TARGET_DIR" || exit 72
    # Replace this shell with the exact selected launcher. Direct execution
    # preserves its original path as $0 and lets the kernel honor its shebang.
    exec "$PAM_TARGET"
    PAM_EXEC_STATUS=$?
    printf '%s\n' "[PAM] cannot execute $PAM_GAME_KIND launcher: $PAM_TARGET (status=$PAM_EXEC_STATUS)" >> "$PAM_LOG" 2>/dev/null
    exit "$PAM_EXEC_STATUS"
  else
    printf '%s\n' '[PAM] EXIT_START without an exact typed launcher; exiting.' >&2
    exit 42
  fi
fi
exit "$PAM_STATUS"
