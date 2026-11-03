# 余烬灯塔启动源码

`launcher.sh` 经共享 assemble 内联 PortMaster 引导，运行时使用 `emberward.gptk` 和 `compat/` 中的图形适配。`scripts/` 负责验证这些文件的身份并选择是否加入显式 PCK，避免将设备会话目录作为包输入。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 启动模板 | `launcher.sh` | 既有存档/输入路径上的启动与文件预检 |
| 按键映射 | `emberward.gptk` | 六个独立校准通道、方向及滚动动作 |
| 图形适配 | `compat/` | EGL 单窗口适配及 Xwayland 元数据入口 |
| 构建 | `scripts/` | 固定负载验证和兼容库构建 |
