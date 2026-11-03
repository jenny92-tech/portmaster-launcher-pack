#!/bin/sh
# INPUT:  d2r_ns_2g 路径清单、Python 3 与已准备的外部 94012 安装
# OUTPUT: 保留现有 2G 档案路径的游戏或只读预检
# POS:    2G 适配版独立可见入口，不与其他暗黑入口互相调用
# PORTMASTER: d2r_ns_2g, Je-暗黑破坏神II_NS（2G版）.sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DATA="$SCRIPT_DIR/d2r_ns_2g"
if [ "${D2R_DIAGNOSTICS:-0}" = 1 ]; then
    :
#@BUILD-LOG
fi
exec python3 "$DATA/libexec/launch.py" "$DATA/install-paths.json" "$@"
