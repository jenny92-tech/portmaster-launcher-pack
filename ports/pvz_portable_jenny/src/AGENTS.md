# PvZ 启动源码

只维护启动和发行层，原生游戏工程在相邻 PvZ-Portable。

## 约束

- 普通目录与档案路径不改名，SH 使用 Je- 前缀。
- 不打包 main.pak、properties、userdata、注册信息、缓存和玩家设置。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 入口 | `launcher.sh` | 保留 pvz_portable_jenny 目录和输入映射 |
| 映射 | `PvzPortable.gptk` | 年度版按键配置 |
| 打包 | `scripts/` | 显式运行时输入与资源排除 |
