# 余烬灯塔

原创像素风爬塔卡牌游戏的 PortMaster 启动包。入口为 `Je-余烬灯塔.sh`，目录为 `emberward/`；已有设置和航行存档继续使用 `emberward/conf/`。

1. 从游戏工程导出 Godot 4.3 PCK，保留与游戏包配套的六键校准映射。
2. 在本仓库运行 `EMBERWARD_PCK=/path/to/emberward.pck _kit/dist_port_zip.sh emberward`。不指定 PCK 时只生成启动器，不收集其他目录里的游戏或存档。
3. 将 ZIP 解压到 Ports，安装 PortMaster 的 `godot_4.3.squashfs` 和 `weston_pkg_0.2.squashfs`，启动 SH。

MiniLoong 沿用原生 Wayland，TrimUI 沿用 Weston/Crusty 的 GLES 路径。私有 EGL 与 Vulkan WSI 仅在原有硬件、运行时和驱动条件满足时作用于游戏进程，不替换系统驱动。Vulkan 画面仍需玩家实际启动确认；`emberward/renderer.cfg` 写入 `gles` 可显式选择兼容路径。

`bash Je-余烬灯塔.sh --check` 只检查包内文件，不运行游戏、应用暂存更新或挂载 runtime。EGL 源码改动后用 `src/scripts/build-compat.py` 重建；可用 `EMBERWARD_CC` 和 `EMBERWARD_LD` 指定 ARM64 clang/LLD 工具。
