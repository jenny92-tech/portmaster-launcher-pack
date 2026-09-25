# LOVE-lite 宿主与引擎

> 用 Lua 5.1 与 SDL2 承载 APP Manager 前端和原生服务。

## 地位

APP Manager 专用运行时的本地适配层；LÖVE API 子集来自相邻 `vendor/` 定制源码。

## 逻辑

入口准备服务和显示环境，Engine 装载 Lua 并绑定原生请求；事件触发更新与重绘，可支持的帧交给 GPU，其他帧走软件缓冲。

## 约束

- 仅覆盖 APP Manager 使用的 LÖVE API，不替代其他游戏使用的完整 LÖVE 11.5。
- 输入由 SDL 宿主接收，不再启动 gptokeyb；原始校准结果只写 APP state，不改系统或 PortMaster。空闲页面按需重绘。
- SDL2 入口受 `sdl-backend` feature 控制，GPU 不支持的帧须保留软件回退。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 引擎与桥接 | `lib.rs` | 装载前端、提供帧/输入接口并绑定 EmbeddedService |
| SDL2 宿主 | `main.rs` | 参数、设备环境、显示选择、事件调度和退出管理 |
| 控制器输入 | `input.rs` | 本地映射优先、SDL 数据库回退、原始按键校准与热插拔 |
| GPU 绘制 | `gpu.rs` | 将图形命令转成 SDL2 绘制并维护纹理缓存 |
