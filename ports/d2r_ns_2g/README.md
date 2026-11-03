# 暗黑破坏神 II：狱火重生 NS

NS 94012 的 2G 内存适配是本仓库唯一的 NS 发行配置。入口为
`Je-暗黑破坏神II_NS（2G版）.sh`，启动器目录为 `d2r_ns_2g/`，使用已准备的
`d2r-linux/rk3566-2gb` 安装及原有档案。

## 准备与打包

外部 D2R Linux 工程负责准备经典精简资源和匹配的 Release 运行时。本端口维护
启动参数、菜单退出和 PortMaster 集成，发行包不含游戏资源、存档或运行缓存。

使用已准备安装生成的入口导入路径：

```sh
D2R_NS_2G_ENTRY=/path/to/prepared-entry.sh _kit/dist_port_zip.sh d2r_ns_2g
```

已有 `install-paths.json` 时，可改用 `D2R_NS_2G_PATHS=/path/to/install-paths.json`。
两种输入互斥；构建校验路径格式，不执行输入脚本或读取目标游戏与档案。
未提供输入时生成启动器骨架，安装使用前须完成路径配置。

将包内 SH 与 `d2r_ns_2g/` 一起解压到 Ports。主选人菜单按 B 打开退出确认，
A 确认、B 取消。`--check` 执行文件预检，保留原有角色、设置及档案位置。

## 支持范围

2G 是内存适配目标。现有验证来自 RK3566 / 4 GiB MiniLoong；2 GiB 实机及其他
固件仍需单独验证，配置名称不构成完整玩法或内存峰值保证。

封面取自 [Blizzard 官方 D2R Key Art](https://blizzard.gamespress.com/en-GB/Diablo-II-Resurrected-Press-Kit)，
游戏图片及外部运行时保留各自许可，见 [LICENSE](LICENSE)。
