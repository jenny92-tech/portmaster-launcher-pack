# STS2 构建与部署

> 组装启动界面、兼容补丁、覆盖包和可分发运行时。

## 地位

连接本移植源码、共享 _kit 与 dist/部署布局的构建入口。

## 逻辑

dist-port.sh 生成核心产物；make-overlay-pck.py 收集移动着色器；assemble-launcher-pack.sh 补齐运行时；deploy-to-device.sh 同步至指定设备。

## 约束

- 启动脚本名称从 manifest.json 读取，UI_ONLY 不触碰已有游戏负载。
- 完整构建需要玩家提供的引用程序集和指定外部运行时；不分发游戏内容或受限 FMOD 运行库。
- 设备部署带有 rsync --delete，必须明确目标且不可作为文档/语法检查运行。
- SDL2 构建受设备 glibc 与 KMSDRM/ALSA 驱动集合约束，不随文档变更重建二进制或版本记录。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| assemble-launcher-pack.sh | `assemble-launcher-pack.sh` | 将核心启动器产物与可再分发 ARM64 运行时组合 |
| build_bundled_sdl.sh | `build_bundled_sdl.sh` | 构建仅供游戏阶段使用的低 glibc KMSDRM/ALSA SDL2 |
| deploy-to-device.sh | `deploy-to-device.sh` | 在明确指定 SSH 目标后构建并部署 STS2 产物 |
| dist-port.sh | `dist-port.sh` | 构建核心兼容 DLL、覆盖包与可部署启动器 |
| make-overlay-pck.py | `make-overlay-pck.py` | 按 Godot PCK 目录与对齐规则打包移动端替代着色器 |
| MANIFEST.md | `MANIFEST.md` | 发布包内容、来源、许可边界与核验说明 |

