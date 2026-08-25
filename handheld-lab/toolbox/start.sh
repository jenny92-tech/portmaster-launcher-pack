#!/bin/sh
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
