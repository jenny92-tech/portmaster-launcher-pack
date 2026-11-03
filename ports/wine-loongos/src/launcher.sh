#!/bin/sh
# INPUT:  wine-loongos 应用目录、私有执行环境及系统 SDL2
# OUTPUT: Ports 游戏列表进程、构建身份与私有启动日志
# POS:    连接发行包代码与当前 LoongOS 掌机的持久 Wine 数据目录
# PORTMASTER: wine-loongos, Je-Wine.sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=${WINE_RUNNER_APP_DIR:-$SCRIPT_DIR/.winecellar/wine-loongos}
export WINE_RUNNER_LIBRARY=${WINE_RUNNER_LIBRARY:-$SCRIPT_DIR}
if [ ! -f "$APP_ROOT/launcher.py" ] || [ ! -d "$APP_ROOT/devices" ]; then
    echo "Wine launcher payload is missing: $APP_ROOT" >&2
    exit 78
fi
if [ -z "${WINE_RUNNER_PYTHON:-}" ]; then
    . "$APP_ROOT/bootstrap.sh"
    wine_bootstrap "$APP_ROOT"
fi
PYTHON_BIN=$WINE_RUNNER_PYTHON
unset PYTHONHOME PYTHONPATH
BASE=$("$PYTHON_BIN" "$APP_ROOT/launcher.py" --print-base "$@")
mkdir -p "$BASE"
export WINE_RUNNER_HOME="$BASE"
exec > "$BASE/launcher.log" 2>&1
#@BUILD-LOG
exec "$PYTHON_BIN" "$APP_ROOT/launcher.py" --base "$BASE" "$@"
