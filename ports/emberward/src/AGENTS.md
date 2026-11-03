# 余烬灯塔启动源码

启动模板经共享 assemble 内联 PortMaster 能力；scripts 固定收集 gptk 和兼容库，可选加入显式 PCK。

## 约束

- 维持 `emberward/conf` 存档位置，不收集 conf、预览工具、缓存或挂载的 runtime。
- Godot/Weston 继续由 PortMaster 管理；共享 WSI 从 `_kit/compat/` 归档读取。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 启动模板 | `launcher.sh` | 沿用 Godot、存档和输入路径的游戏启动与只读预检 |
| 按键映射 | `emberward.gptk` | 六个独立校准通道及方向、滚动映射 |
| 图形适配 | `compat/` | 进程内 EGL 适配和 Xwayland SHM 入口 |
| 构建 | `scripts/` | 兼容库重建和标准负载组装 |
