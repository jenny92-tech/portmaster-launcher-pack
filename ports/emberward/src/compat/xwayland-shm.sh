#!/bin/sh
# INPUT:  EMBERWARD_XWAYLAND 和 Weston 的 Xwayland 参数
# OUTPUT: 仅用于窗口和输入元数据的 Xwayland SHM 进程
# POS:    保留游戏 Crusty/GLES 渲染的独立辅助入口
# Headless window/input service only; game rendering stays in Crusty/SDL.
exec "${EMBERWARD_XWAYLAND:?Missing game-owned Xwayland path}" -shm "$@"
