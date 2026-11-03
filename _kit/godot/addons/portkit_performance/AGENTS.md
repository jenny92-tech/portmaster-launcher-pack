# Godot 4 性能浮层实现

宿主安装 CanvasLayer 后，`overlay.gd` 管理显示和低频刷新，`metrics.gd` 汇总 Godot 统计，并在 Linux/Android 补充当前进程 RSS。可选编辑器插件只负责自身 autoload 注册。

## 约束

- 运行时不依赖编辑器、C#、外部命令或原生扩展；输入动作由宿主映射，浮层不消费事件。
- 隐藏后停止采样；进程内存只读取有界的 `/proc/self/status`，不扫描其他进程。
- 安装与卸载保持幂等，编辑器清理仅作用于自身注册；指标口径见上级 README。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 浮层场景 | `overlay.tscn` | 右上角无输入控件与样式 |
| 浮层控制 | `overlay.gd` | 幂等安装、显示状态与低频刷新 |
| 统计采集 | `metrics.gd` | Godot 内置统计和进程 RSS |
| 编辑器插件 | `plugin.gd` | 可选注册及清理自身 autoload |
| 插件清单 | `plugin.cfg` | Godot 编辑器插件入口 |
