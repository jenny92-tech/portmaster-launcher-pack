# Sentry 反馈替代控件

> 保留反馈场景可解析的无操作 Godot Control。

## 地位

STS2 静态覆盖层中的 Sentry 用户反馈兼容叶子目录。

## 逻辑

同名脚本只继承 Control，不引用设备缺失的 SentrySDK/SentryEvent 类型。

## 约束

- 保持原资源路径和基类以满足既有场景引用。
- 此目录属于覆盖包输入，内容会随上层覆盖流程复制。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| user_feedback_form.gd | `user_feedback_form.gd` | 避免场景加载引用 ARM64 不存在的 Sentry SDK 类型 |

