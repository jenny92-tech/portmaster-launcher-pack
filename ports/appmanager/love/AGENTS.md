# APP Manager 界面

> 以 Lua 页面和原生服务桥接组织应用管理界面。

## 地位

APP Manager 的表现层，由独立 LOVE-lite runtime 加载，共享 `_kit/love/kit.lua` 控件。

## 逻辑

`main.lua` 装配 native、model、operations、pages 和 environment；原生任务返回快照/事件，经 model 和 operations 更新页面与确认状态。

## 约束

- 只有 `app_native.lua` 直接跨越 Rust 桥接边界；设备策略和文件操作由原生服务负责。
- 操作确认绑定库存 revision；后台快照不能让旧确认计划作用于新库存。
- UI 使用 Lua 5.1 兼容语法与 kit 控件，保留任务忙碌、取消和退出反馈。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 应用入口 | `main.lua` | 装配模块，加载初始快照并轮询前后台任务 |
| 原生边界 | `app_native.lua` | 请求 Rust 服务并校验响应和任务事件 |
| 按键校准 | `app_input.lua` | 控制器示意、步骤高亮、测试与保存覆盖层；经 app_native 获取状态 |
| 共享模型 | `app_model.lua` | 保存环境/库存，推导能力和展示数据，维护缓存 |
| 操作协调 | `app_operations.lua` | 管理确认计划、任务生命周期、库存刷新与退出 |
| 业务页面 | `app_pages.lua` | 构建启动、游戏管理、Runtime、清理、安装等页面 |
| 环境管理 | `app_environment.lua` | PortMaster 安装修复、更新与设备风险确认 |
| 旧输入映射 | `ui.gptk` | 保留的 gptokeyb 操作语义参考；当前宿主直接读取 SDL，不启动助手 |
