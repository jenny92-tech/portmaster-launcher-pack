# ARM64 扩展覆盖

此树对应游戏的 `res://addons/`。FMOD 与 Spine 的 .gdextension 声明负责选择 Linux ARM64 库及依赖路径；Sentry 子树提供 Node/Control 类型占位，让资源加载无需原生 Sentry SDK。构建器只复制声明和脚本，实际动态库由匹配运行环境提供。

## 约束

- 路径必须保持与原游戏 res://addons 资源位置一致。
- 本目录不包含 FMOD 或 Spine 运行时动态库，库由设备侧提供。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| fmod | `fmod/` | FMOD 架构入口及运行库依赖映射 |
| sentry | `sentry/` | 自加载和反馈场景的无操作脚本 |
| spine | `spine/` | 包含 ARM64 的显式 res:// 扩展库映射 |
