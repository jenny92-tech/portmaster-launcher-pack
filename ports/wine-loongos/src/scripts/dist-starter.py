#!/usr/bin/env python3
# INPUT:  已构建的运行器、匹配公共组件和独立游戏适配 ZIP
# OUTPUT: 无游戏资源、无需 PortMaster 的复制到卡入门包
# POS:    组合既有独立产物，避免新用户手工合并多个安装包
import argparse
from pathlib import Path, PurePosixPath
import zipfile


def build(archives, output):
    files = {}
    for path in archives:
        with zipfile.ZipFile(path) as source:
            for item in source.infolist():
                name = PurePosixPath(item.filename)
                if name.is_absolute() or ".." in name.parts:
                    raise ValueError("发行归档路径越界")
                if item.is_dir() or str(name) == "port.json":
                    continue
                payload = source.read(item)
                if str(name) in files and files[str(name)][1] != payload:
                    raise ValueError("入门包包含冲突文件：" + str(name))
                files[str(name)] = (item.external_attr, payload)
    files["先看这里.txt"] = (0o100644 << 16, """迷你龙 LoongOS 1.4.0.36 入门包（不含游戏）
1. 把本 ZIP 完整解压到 SD 卡根目录，合并 roms/，不要再把整个包套进 roms/ports/。
   规范入口位于 roms/windows/；没有 Windows 分类的迷你龙使用 roms/ports/ 中的首页桥接。
2. 刷新系统游戏列表后打开 Je-Wine；不需要先安装 PortMaster 或 Python。
   已有 PortMaster 时优先复用它的手柄映射与可用输入工具；没有则使用随包工具。
3. 选择游戏，按提示把你自己的完整 Windows 游戏文件放到 roms/windows/<游戏ID>/data/。
   EXE 要直接在这个目录内，不要再多套一层文件夹。
4. 如果提示需要准备游戏入口，先按游戏适配包说明在电脑完成准备，再复制完整文件夹；本包不包含任何游戏资源。
5. 选择游戏启动；首次启动在 roms/windows/.winecellar/state/ 内创建私有运行映像并安装公共环境，以后所有游戏共用。
   也可以选择“安装 / 补齐运行环境”提前安装。
   单独提供的离线运行环境 ZIP 可直接放在 SD 卡根目录，无需解压、无需固定外部文件名；运行器按包内身份清单和固定组件校验值识别。
退出游戏：Select＋Start 请求正常关闭，请稍候。
仅登记上述迷你龙固件。其他掌机需要自己的机型与环境适配；不能只看同为 ARM64 就安装。
当前安装与显示交接已完成本地验证，掌机验收尚待完成。
本包沿用 ROCKNIX 的 Windows 目录/脚本入口与社区 bottle.json 描述，尚未登记 ROCKNIX 固件的硬件环境。
""".encode())
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as target:
        for name, (mode, payload) in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.external_attr = mode
            target.writestr(info, payload)
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--game", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build([args.runner, args.runtime, *args.game], args.output)
