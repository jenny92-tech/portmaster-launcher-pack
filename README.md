# Jenny Loong Launcher Pack

ARM64 Linux 掌机的游戏启动器、App Manager 和共享构建工具。
普通游戏通过 PortMaster 的 LÖVE 设置界面保存选项，再由 Shell 启动游戏；
App Manager 使用独立的 Rust/LOVE-lite 程序，可在 PortMaster 缺失时启动并修复环境。

首页入口统一使用 `Je-游戏名`，例如 `Je-黑神话像素版[中]`、`Je-空洞骑士[中]`；Wine 入口为 `Je-Wine`。APP Manager 保留原名，按名称排序时位于 Je- 入口之前。内部游戏目录和存档路径保持各端口自己的标识。
从旧名称更新时，移除对应的旧入口 SH 和同名封面，再安装新包；保留原有游戏资源目录和存档。

## 端口

| 端口 | 用途 |
|---|---|
| [hk](ports/hk) | 空洞骑士，Rudroid/Unity |
| [silksong](ports/silksong) | 空洞骑士：丝之歌，Rudroid/Unity 6 |
| [heishenhua](ports/heishenhua) | 像素黑神话，Rudroid/Unity |
| [terraria](ports/terraria) | 泰拉瑞亚，玩家 APK 资源准备与 Rudroid 启动 |
| [vampiresurvivors114](ports/vampiresurvivors114) | 吸血鬼幸存者 1.14.111，Unity 6/PAD |
| [sts2](ports/sts2) | 杀戮尖塔 2，C# Godot/SDL2 |
| [batomon](ports/batomon) | Batomon Showdown Demo，Godot 直接运行入口 |
| [d2r_ns_2g](ports/d2r_ns_2g) | 暗黑破坏神II NS，统一采用 2G 适配，沿用已准备安装与原档案 |
| [emberward](ports/emberward) | 原创余烬灯塔，Godot 4.3 与显式 PCK 导出打包 |
| [pvz_portable_jenny](ports/pvz_portable_jenny) | 维护版植物大战僵尸年度版，不含原游戏资源 |
| [sunkendragon](ports/sunkendragon) | 龙沉异世录原生移植实验，已暂停 |
| [appmanager](ports/appmanager) | Port、回收站、Runtime 与 PortMaster 环境管理 |
| [recorder](ports/recorder) | 后台采帧、停止后合成视频的录屏应用 |
| [wine-loongos](ports/wine-loongos) | 独立 Wine 运行器，自带私有 Python，当前适配迷你龙 LoongOS |

支持范围、资源准备和限制见各端口文档。游戏本体与受限运行库由玩家提供。

## 构建与部署

共享工具需要 Bash、Python 3.11+；原生组件另需 Rust 和 ARM64 容器构建环境。
端口所需的 Godot、.NET、游戏资源及外部运行库见各自说明。
在仓库根目录执行：

```sh
_kit/dist_port.sh hk                  # ports/hk/dist/
_kit/dist_port_zip.sh appmanager      # PortMaster ZIP
_kit/dist_trimui_app.sh recorder      # TrimUI APP ZIP
```

`ports/<port>/dist/` 是组包暂存；核验后保留根 `dist/` 的正式包或 `dist/ports/<port>/`
交付目录，并清理重复暂存。部署这些已校验产物，不将模板或 `_kit/` 复制到设备。
通常将 SH 放固件的 Ports 菜单，其余内容放端口数据目录；具体布局以该端口说明为准。
Je-Wine 的运行器和游戏适配 ZIP 解压到 SD 卡根目录，离线运行环境 ZIP 可直接放在卡根目录识别导入：规范入口在 `roms/windows/`，运行器与共享组件在其 `.winecellar/` 下，`roms/ports/` 提供首页桥接。布局详见 [Je-Wine](ports/wine-loongos/README.md)。

`manifest.json` 是仓库内部构建输入，构建器据此生成发行 `port.json`。
普通设置页源码在 `love/`，发行副本在 `dist/love_ui/`；专用构建源码在 `src/`。
封面使用 `screenshot.png`，共用紫猫角标与裁切规范见 [artwork](_kit/artwork/README.md)。

## 文档

| 入口 | 内容 |
|---|---|
| [_kit](_kit/README.md) | 构建入口、共享 Shell、Unity 配置与部署边界 |
| [UIKit](_kit/love/README.md) | LÖVE 控件、输入、布局与状态契约 |
| [App Manager](ports/appmanager/README.md) | 管理、安装、远程配对及日志 |
| [Config](config/README.md) | 声明式设备配置与生成检查 |
| [Handheld DevTools](handheld-lab/README.md) | 通用设备探针与 SSH/ADB 控制 |
| [APP 评估](lab/README.md) | 配置、业务、固件用户态测试 |

开发导航和仓库规则见 [AGENTS.md](AGENTS.md)。
环境准备、验证和贡献约定见 [开发指南](CONTRIBUTING.md)。

## 授权

[CC BY-NC-SA 4.0](LICENSE)，要求署名、非商业使用和相同方式共享。
游戏及第三方运行库保留各自授权，项目授权不包含其分发权。
