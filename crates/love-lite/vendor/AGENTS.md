# LOVE-lite 的定制上游依赖

此目录保存受版本控制的 path 依赖。`love-api` 将 Lua 接口和共享状态连接到 `sprite-to-text` 的像素缓冲，SDL 窗口、事件采集及最终呈现留在上级 `src/`。

## 约束

- 导入依据见 `../UPSTREAM.md`，许可见 `../LICENSE-UPSTREAM-APACHE-2.0.txt`；同步时核对上游身份和本地适配，不能按缓存覆盖或清理。
- 保留生产所需 API 与像素后端，不纳入上游游戏资源、终端渲染器或游戏专属补丁。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| LÖVE 子集 | `love-api/` | Lua API、共享状态与图形绑定，见其 AGENTS.md |
| CPU 回退 | `sprite-to-text/` | 纯软件像素缓冲与绘制后端，见其 AGENTS.md |
