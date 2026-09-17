# Sentry ARM64 占位脚本

> 替代设备端不可用的 Sentry 初始化与用户反馈实现。

## 地位

静态 addons 覆盖中保留 Godot 场景引用有效性的兼容分支。

## 逻辑

SentryInit 继承 Node 保持无操作；user_feedback 中表单继承 Control，避免引用未提供的原生 SDK 类型。

## 约束

- 只保留加载兼容，不模拟遥测或反馈上传功能。
- 目录结构映射原始 res://addons/sentry 路径，改名会影响资源引用。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| SentryInit.gd | `SentryInit.gd` | 无操作的 Sentry 自加载占位节点 |
| user_feedback | `user_feedback/` | 无操作的用户反馈表单控件 |

