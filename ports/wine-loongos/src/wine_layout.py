#!/usr/bin/env python3
# INPUT:  机型库目录、入口所在目录与显式路径覆盖
# OUTPUT: ROCKNIX Windows 库、私有状态和 SD 卡分发路径
# POS:    集中定义游戏库与 .winecellar 布局，避免各入口分别猜路径
from pathlib import Path
import os


WINDOWS_REL = Path("roms/windows")
APP_REL = WINDOWS_REL / ".winecellar/wine-loongos"
PACKAGES_REL = WINDOWS_REL / ".winecellar/packages"


def resolve_library(profile, override=None):
    value = override or os.environ.get("WINE_RUNNER_LIBRARY") or profile.get("library_directory")
    if not isinstance(value, (str, Path)) or not str(value) or not Path(value).is_absolute() or Path(value) == Path("/"):
        raise ValueError("机型定义需要绝对路径 library_directory，指向 roms/windows")
    return Path(value).resolve()


def state_directory(library):
    return Path(library) / ".winecellar/state"


def offline_directory(library):
    return Path(library) / ".winecellar/packages"


def ports_bridge(entry):
    import shlex
    return ('''#!/bin/sh
# INPUT:  同卡 roms/windows 下的规范游戏入口
# OUTPUT: 跳转到 Windows 游戏库，不携带运行库或游戏资源
# POS:    为没有 Windows 分类的固件提供 Ports 首页桥接
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$SCRIPT_DIR/../windows"/''' + shlex.quote(entry) + ''' "$@"
''').encode()
