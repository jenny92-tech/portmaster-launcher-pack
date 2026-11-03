# Sentry ARM64 占位脚本

原游戏自加载和反馈场景仍会解析 Sentry 脚本路径，因此覆盖树保留同名文件。SentryInit.gd 仅继承 Node，反馈表单仅继承 Control；两者都不引用 SentrySDK/SentryEvent，避免 ARM64 缺少原生扩展时的脚本类型错误。

## 约束

- 只保留加载兼容，不模拟遥测或反馈上传功能。
- 目录结构映射原始 res://addons/sentry 路径，改名会影响资源引用。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| SentryInit.gd | `SentryInit.gd` | 仅保留 Node 基类的自加载脚本 |
| user_feedback | `user_feedback/` | 仅保留场景可加载的 Control 类型 |
