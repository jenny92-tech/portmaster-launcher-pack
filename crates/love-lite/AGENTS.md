# APP Manager 专用 LOVE-lite

APP Manager 将 Lua 前端交给此 Rust 运行时，宿主同时持有嵌入式管理服务。SDL2 收集事件并呈现 API 层产生的图形命令；可支持的帧优先走 GPU，其余帧使用软件缓冲。

## 约束

- 此运行时只实现 APP 所需的 LÖVE 子集；普通游戏启动器继续使用完整 LÖVE。
- `vendor/` 是定制源码而非下载缓存，更新时维护来源、本地差异和上游许可。
- 预置可执行文件与 source revision 由同一次真实构建产生，源码树内文档也参与身份计算。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 构建声明 | `Cargo.toml` | Lua 5.1、SDL2 feature、本地依赖与运行入口声明 |
| 使用与契约 | `README.md` | 生产能力、适用范围和构建测试说明 |
| 上游来源 | `UPSTREAM.md` | 导入来源、提交身份和本地适配边界 |
| 上游许可证 | `LICENSE-UPSTREAM-APACHE-2.0.txt` | 上游代码 Apache-2.0 授权文本 |
| 宿主与引擎 | `src/` | SDL2 循环、GPU 适配与原生桥接，见其 AGENTS.md |
| 运行验证 | `tests/` | API/字体/真实 UI 与服务桥接契约，见其 AGENTS.md |
| 定制依赖 | `vendor/` | LÖVE 子集与 CPU 像素后端，见其 AGENTS.md |
