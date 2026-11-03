# LOVE-lite 上游衍生源码

> 保存运行时使用的定制 LÖVE API 和软件像素渲染输入。

## 地位

LOVE-lite 内的受版本控制 path 依赖边界，来源记录在 `../UPSTREAM.md`。

## 逻辑

`love-api` 负责 Lua 绑定和共享状态，并调用 `sprite-to-text` 提供的像素缓冲；宿主 SDL2 代码位于上级 `src/`。

## 约束

- 这里不是下载缓存或生成目录，源码和本地改动必须纳入维护。
- 上游授权保存在 `../LICENSE-UPSTREAM-APACHE-2.0.txt`，同步时同时核对来源和本地适配。
- 生产范围不包含上游游戏资产、终端渲染器和游戏专属补丁。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| LÖVE 子集 | `love-api/` | Lua API、共享状态与图形绑定，见其 AGENTS.md |
| CPU 回退 | `sprite-to-text/` | 纯软件像素缓冲与绘制后端，见其 AGENTS.md |
