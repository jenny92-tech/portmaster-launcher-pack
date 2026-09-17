# STS2 设备实验脚本

> 保存 SDL2 启动实验与每秒内存观测工具。

## 地位

PCK 移植方案的设备端诊断辅助入口，不是当前 LÖVE 正式启动模板。

## 逻辑

launcher-sdl2.sh 准备 PortMaster/SDL2/交换空间后启动游戏；rss-watch.sh 从 /proc 和内核日志持续输出内存 CSV。

## 约束

- 脚本涉及设备进程、swap、内核参数及日志，不作为本机文档验证运行。
- 正式启动行为以 ports/sts2/love/launcher.sh.template 为准。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| launcher-sdl2.sh | `launcher-sdl2.sh` | 保留用于 STS2 移植实验的设备端 SDL2 启动入口 |
| rss-watch.sh | `rss-watch.sh` | 记录设备端 STS2 进程存活与 Mali 内存压力 |

