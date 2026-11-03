# STS2 设备实验脚本

这里是资源方案的独立设备检查入口：launcher-sdl2.sh 准备 PortMaster、SDL2 和交换空间，再运行游戏；rss-watch.sh 通过 /proc 与内核信息持续记录内存 CSV。它们不经过正式 LÖVE 模板，不能作为正式入口行为的替代证明。

## 约束

- 脚本会操作设备进程、swap 和内核参数，执行前必须核验目标与恢复条件。
- 正式启动行为以 ports/sts2/love/launcher.sh.template 为准。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| launcher-sdl2.sh | `launcher-sdl2.sh` | 设备 SDL 会话准备与实验性游戏启动 |
| rss-watch.sh | `rss-watch.sh` | 进程存活、RSS 和 Mali 内存压力观察 |
