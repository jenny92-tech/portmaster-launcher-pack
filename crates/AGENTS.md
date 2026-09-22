# 原生 Rust 组件

> 提供设备策略、APP 管理服务、专用 UI 运行时和游戏启动辅助。

## 地位

仓库的原生实现域；上层由 Lua/UIKit、Shell 启动器和打包流程消费。

## 逻辑

`portkit-core` 提供通用配置与基础能力，`appmanager-core` 实现 APP 业务，`appmanager-service` 编排任务，`love-lite` 承载前端；独立 `portkit-launcher` 为游戏包提供轻量文件辅助。

## 约束

- 依赖边界保持单向，游戏启动辅助不依赖 APP 服务或网络核心。
- 继承根目录的首次发布前版本纪律；头注释初始化不改变逻辑、版本或预置二进制。
- LOVE-lite 的 vendor 源码是受版本控制的定制输入，上游来源和授权必须保留。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 通用核心 | `portkit-core/` | 数据驱动配置、设备解析、下载和文件基础，见其 AGENTS.md |
| APP 业务核心 | `appmanager-core/` | 清单、安装、管理与恢复事务，见其 AGENTS.md |
| APP 原生服务 | `appmanager-service/` | 进程内任务、快照和局域网管理，见其 AGENTS.md |
| APP UI 运行时 | `love-lite/` | Lua/LÖVE 子集、SDL2 呈现及原生桥接，见其 AGENTS.md |
| 游戏启动辅助 | `portkit-launcher/` | 轻量 CLI、配置/字体/封面等本地操作，见其 AGENTS.md |
| 桌面下载 CLI | `portkit-download/` | 直接复用通用核心的薄下载命令 |
