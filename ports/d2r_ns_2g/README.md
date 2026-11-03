# 暗黑破坏神 II：狱火重生 NS（2G 适配版）

独立入口为 `Je-暗黑破坏神II_NS（2G版）.sh`，启动器目录为 `d2r_ns_2g/`。与原来的 `d2r_ns/` 端口并存，继续使用已经安装的 `d2r-linux/rk3566-2gb` 资源与档案，不迁移角色或设置。

1. 先在独立 D2R Linux 工程按 `dm/linux/AGENTS.md` 准备经典精简资源，安装匹配的 94012 Release 运行时。该工程和游戏数据需另行准备，保留已有角色和设置。
2. 将该安装生成的 C197 正式 SH 作为明确输入，运行 `D2R_NS_2G_ENTRY=/path/to/prepared-entry.sh _kit/dist_port_zip.sh d2r_ns_2g`。构建只读取其中的固定路径，不执行该 SH，也不遍历游戏、档案或缓存目录。
3. 将 ZIP 中的 SH 和 `d2r_ns_2g/` 一起解压到 Ports，再启动 SH。已有正式 SH 会被同名 Pack 入口替换，角色与资源路径不变；主选人菜单 B 打开退出确认，A 确认、B 取消。

不指定 `D2R_NS_2G_ENTRY` 时只生成公共启动器骨架，首次使用前仍需为已准备安装导入路径。游戏运行时和原生模块继续由 D2R Linux 工程构建；本端口维护启动参数与 Pack 集成，不复制引擎源码或游戏数据。

`bash Je-暗黑破坏神II_NS（2G版）.sh --check` 只检查外部文件，不启动游戏或修改档案。2G 是适配配置名称；当前验证来自 4 GB MiniLoong，不代表已经通过 2 GB 硬件验收。
