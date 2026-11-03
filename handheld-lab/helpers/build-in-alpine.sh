#!/bin/sh
# INPUT:  Alpine apk、C/Linux 头文件与 build-input-helper.sh
# OUTPUT: 指定目录下静态编译的掌机辅助程序
# POS:    在临时 Alpine 构建环境内准备依赖并构建原生工具
set -eu

component_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
apk add --no-cache build-base linux-headers >/dev/null
HANDHELD_DEVTOOLS_STATIC=1 sh "$component_root/helpers/build-input-helper.sh" \
    "${1:-$component_root/build}"
