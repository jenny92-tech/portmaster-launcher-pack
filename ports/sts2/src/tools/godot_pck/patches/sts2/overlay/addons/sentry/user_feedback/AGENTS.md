# Sentry 反馈替代控件

反馈场景按原资源路径加载 user_feedback_form.gd。本文件是空 Control 替代类型，只保障场景能解析脚本及基类；实际反馈表单逻辑和上传服务不在此实现。

## 约束

- 文件路径和 Control 基类须与引用它的游戏场景一致。
- 脚本随上层静态覆盖复制；不能将可加载视为反馈功能可用。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| user_feedback_form.gd | `user_feedback_form.gd` | 无 SDK 引用、无方法实现的 Control 脚本 |
