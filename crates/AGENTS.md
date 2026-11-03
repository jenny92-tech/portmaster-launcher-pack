# 原生组件与依赖边界

Rust 工作区按基础能力、应用业务、服务编排和 UI 宿主分层。Lua 与 Shell 通过这些边界消费原生能力；游戏包另用独立的轻量启动辅助程序。

## 约束

- 能力由 PortKit 经应用核心、嵌入服务提供给 LOVE-lite，调用依赖指向下层；轻量启动辅助保持本地文件能力与独立依赖树。
- LOVE-lite 的 vendor 是维护中的定制源码，修改时保留上游来源与许可。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 通用核心 | `portkit-core/` | 数据驱动配置、设备解析、下载和文件基础，见其 AGENTS.md |
| APP 业务核心 | `appmanager-core/` | 清单、安装、管理与恢复事务，见其 AGENTS.md |
| APP 原生服务 | `appmanager-service/` | 进程内任务、快照和局域网管理，见其 AGENTS.md |
| APP UI 运行时 | `love-lite/` | Lua/LÖVE 子集、SDL2 呈现及原生桥接，见其 AGENTS.md |
| 游戏启动辅助 | `portkit-launcher/` | 轻量 CLI、配置/字体/封面等本地操作，见其 AGENTS.md |
| 桌面下载 CLI | `portkit-download/` | 直接复用通用核心的薄下载命令 |
