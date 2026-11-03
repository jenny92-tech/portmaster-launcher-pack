# PvZ 启动源码

设备侧 `launcher.sh` 保持 pvz_portable_jenny 布局，接入 PortMaster 控制器配置并使用 `PvzPortable.gptk`。主机侧 `scripts/` 只组装启动层和显式运行时，因此修改游戏代码应进入相邻 PvZ-Portable 工程。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 入口 | `launcher.sh` | Bash 重入、既有目录和控制器环境 |
| 映射 | `PvzPortable.gptk` | 年度版游戏的按键动作 |
| 打包 | `scripts/` | 运行时白名单收集及 PortMaster 包元数据 |
