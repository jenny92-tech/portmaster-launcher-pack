#!/bin/sh
# INPUT:  目标容器名、绝对工作路径与工具箱镜像
# OUTPUT: 共享目标 PID/网络及卷的调试侧车容器
# POS:    为显式调试任务附加 SYS_PTRACE 工具箱而不替换目标系统
set -eu

target=${1:-}
[ -n "$target" ] || {
    printf 'usage: %s TARGET_CONTAINER [TOOLBOX_CONTAINER] [WORK_DIR]\n' "$0" >&2
    exit 64
}
toolbox=${2:-"$target-debug"}
work_dir=${3:-"$(pwd)/handheld-devtools-work"}
image=${HANDHELD_DEVTOOLS_TOOLBOX_IMAGE:-handheld-devtools-toolbox}

case $work_dir in
    /*) ;;
    *) printf 'WORK_DIR must be absolute: %s\n' "$work_dir" >&2; exit 64 ;;
esac
mkdir -p "$work_dir"

if ! docker container inspect "$target" >/dev/null 2>&1; then
    printf 'target container not found: %s\n' "$target" >&2
    exit 66
fi
if docker container inspect "$toolbox" >/dev/null 2>&1; then
    printf 'toolbox container already exists: %s\n' "$toolbox" >&2
    exit 73
fi

docker run -d --init --name "$toolbox" \
    --pid "container:$target" \
    --network "container:$target" \
    --volumes-from "$target" \
    --volume "$work_dir:/work" \
    --cap-add SYS_PTRACE \
    --security-opt seccomp=unconfined \
    "$image"
