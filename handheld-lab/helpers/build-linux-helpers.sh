#!/bin/sh
# INPUT:  Docker、Alpine 构建镜像与 build-in-alpine.sh
# OUTPUT: build/amd64 与 build/arm64 辅助程序集合
# POS:    为虚拟机和掌机分别生成静态 Linux 原生工具
set -eu

component_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
image=${HANDHELD_DEVTOOLS_BUILD_IMAGE:-alpine:3.22}

for architecture in amd64 arm64; do
    docker run --rm --platform "linux/$architecture" \
        --volume "$component_root:/src" --workdir /src \
        "$image" sh helpers/build-in-alpine.sh "/src/build/$architecture"
done
