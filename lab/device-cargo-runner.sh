#!/bin/sh
# INPUT:  Cargo 测试可执行文件、PAM_LAB_USERSPACE_PROFILE 与采集的设备 loader/运行库
# OUTPUT: 在指定设备用户态执行 Cargo 测试进程
# POS:    为 ARM64 业务测试注入真实固件动态链接环境
set -eu

binary=${1:?missing Cargo test executable}
shift
libs="/workspace/.pam-lab/userspace/${PAM_LAB_USERSPACE_PROFILE:?}/runtime-libs"
export PAM_LAB_TEST_EXECUTABLE="$binary"
exec "$libs/ld-linux-aarch64.so.1" --library-path "$libs" "$binary" "$@"
