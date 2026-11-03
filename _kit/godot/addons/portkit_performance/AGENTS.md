# Godot 性能浮层

轻量 Godot 4 CanvasLayer，读取内置统计并在 Linux/Android 补充当前进程 RSS。安装和各指标限制见上级 README。

## 约束

- 运行时文件不依赖编辑器、C#、外部命令或原生扩展；输入动作由宿主映射，不抢事件。
- 隐藏时不采样；只读取本进程的有界 `/proc/self/status`，不扫描其他进程。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 浮层场景 | `overlay.tscn` | 右上角无输入控件与样式 |
| 浮层控制 | `overlay.gd` | 幂等安装、显示状态与低频刷新 |
| 统计采集 | `metrics.gd` | Godot 内置统计和进程 RSS |
| 编辑器插件 | `plugin.gd` | 可选注册及清理自身 autoload |
| 插件清单 | `plugin.cfg` | Godot 编辑器插件入口 |
