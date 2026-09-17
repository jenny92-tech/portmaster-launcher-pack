#!/bin/sh
# INPUT:  Docker、toolbox/Dockerfile 与组件构建上下文
# OUTPUT: 按需调试工具箱镜像
# POS:    构建包含原生开发与调试工具的独立容器环境
set -eu

component_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
image=${HANDHELD_DEVTOOLS_TOOLBOX_IMAGE:-handheld-devtools-toolbox}
docker build --tag "$image" --file "$component_root/toolbox/Dockerfile" "$component_root"
