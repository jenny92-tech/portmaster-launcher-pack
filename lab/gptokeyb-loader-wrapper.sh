#!/bin/sh
# INPUT:  PAM_LAB_DEVICE_LOADER、PAM_LAB_DEVICE_LIBS 与 PAM_LAB_GPTOKEYB_REAL
# OUTPUT: 使用指定动态加载器执行真实 gptokeyb
# POS:    在用户态冒烟测试中保持输入辅助程序的固件 ABI
set -eu

exec "${PAM_LAB_DEVICE_LOADER:?}" \
    --library-path "${PAM_LAB_DEVICE_LIBS:?}" \
    "${PAM_LAB_GPTOKEYB_REAL:?}" "$@"
