# ARM64 扩展覆盖

> 提供 FMOD/Spine 架构映射和 Sentry 脚本替代。

## 地位

静态覆盖目录中与原始 addons 路径对应的扩展兼容层。

## 逻辑

fmod 与 spine 提供 .gdextension 映射；sentry 保留无原生 SDK 依赖的 Node/Control 脚本。

## 约束

- 路径必须保持与原游戏 res://addons 资源位置一致。
- 本目录不包含 FMOD 或 Spine 运行时动态库，库由设备侧提供。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| fmod | `fmod/` | FMOD 的 Linux ARM64 库与依赖映射配置 |
| sentry | `sentry/` | 不依赖原生 Sentry 扩展的占位脚本 |
| spine | `spine/` | 含 ARM64 且使用显式 res:// 路径的 Spine 扩展映射 |

