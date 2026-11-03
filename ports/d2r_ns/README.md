# 暗黑破坏神II：狱火重生（NS）

独立标识为 `d2r_ns`，适配 NS 94012 与已验证的 MiniLoong 经典预设。当前整机验收为 RK3566 / 4 GB / LoongOS，其他构建和设备需另行验证。

1. 准备自己持有的同版本资源。输入目录包含 `runtime/`、`native/`、`game/`、`overlays/world/` 和 `overlays/menu/`；生成工具不读取任何玩家存档。
2. 在仓库根运行 `_kit/dist_port.sh d2r_ns` 生成启动器。完整私人包使用 `python3 ports/d2r_ns/src/scripts/package.py --prepared <资源目录> --output <新输出目录> --archive <文件.7z> --password <密码>`。它按原优先级合并资源，保留生效内容，移除重复基础层、旧模块、报告和运行状态。
3. 将 `Je-暗黑破坏神II_NS.sh` 与 `d2r_ns/` 一起解压到 Ports，启动 SH。设备需安装 PortMaster 及其 LÖVE runtime；首次启动自动准备游戏/UI 运行环境和新的游戏设置，支持禁止执行程序的 SD 卡。

存档和运行文件集中在 `/userdata/d2r_ns/` 下的 `profile/`、`runtime/`，资源与界面状态留在游戏文件夹。更新保留已有存档；制作完整包不会带入玩家角色、共享仓库或设备标识。开始/退出界面沿用共享 UIKit，游戏设置在游戏内调整。

图标使用 [Blizzard 官方 D2R 竖版 Key Art](https://blizzard.gamespress.com/en-GB/Diablo-II-Resurrected-Press-Kit)，方形裁切后叠加项目统一紫猫边框；游戏图片不属于启动器的 CC 授权。
