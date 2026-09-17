# APP Manager 专用 LOVE-lite

> 用有限 LÖVE API 与 SDL2 运行现有 Lua/UIKit 前端。

## 地位

APP Manager 的生产 UI 运行时，内嵌原生服务；普通游戏启动器仍使用完整 LÖVE 运行库。

## 逻辑

Rust 宿主装载 Lua UI，定制 API 层提供图形与输入契约，SDL2 优先 GPU 绘制并支持 CPU 回退；契约测试同时运行小型场景和真实前端。

## 约束

- 专用运行时不能作为完整 LÖVE 的通用替代品。
- `vendor/` 是定制且受版本控制的构建输入，保留来源和上游许可证。
- 文档或头注释初始化不重建预置运行时，不更新来源 revision 或包版本。

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
