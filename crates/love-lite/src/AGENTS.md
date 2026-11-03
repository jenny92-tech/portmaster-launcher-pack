# LOVE-lite 宿主与引擎

> 用 Lua 5.1 与 SDL2 承载 APP Manager 前端和原生服务。

## 地位

APP Manager 专用运行时的本地适配层；LÖVE API 子集来自相邻 `vendor/` 定制源码。

## 逻辑

入口准备服务和显示环境，Engine 装载 Lua 并绑定原生请求；事件触发更新与重绘，可支持的帧交给 GPU，其他帧走软件缓冲。

## 约束

- 仅覆盖 APP Manager 使用的 LÖVE API，不替代其他游戏使用的完整 LÖVE 11.5。
- 输入由 SDL 宿主接收，不再启动 gptokeyb；原始校准结果只写 APP state，不改系统或 PortMaster。空闲页面按需重绘。
- 自动校准仅在 SDL 不能提供 APP 基础方向和动作映射时启用；不得用 APP 随包 GUID 白名单排除固件、内置或 PortMaster 已传入的可用映射。有效重连退出断开提示，手动校准由设置/Home/F2 发起，不用任意双键长按触发。
- 映射加载顺序为随包通用库、正式配置解析到的 PortMaster 库、APP 私有校准；只读映射数据，不执行 control.txt/get_controls 或修改共享库。PortMaster 缺失时保留独立运行能力。
- 父进程 SDL 映射作为普通回退导入；main 在 SDL 初始化前调用 prepare_mapping_hint，清除其进程内 SDL hint 高优先级，避免覆盖 APP 私有校准，不修改父进程环境或磁盘映射。
- `pam_input_layout` 提供已保存的 A/B、X/Y 互换偏好，仅调整 APP 的控制器语义；改变布局时等待当前按键释放，避免一次按下触发两个动作。校准仍按原始标记采集，不改其映射文件。
- SDL2 入口受 `sdl-backend` feature 控制，GPU 不支持的帧须保留软件回退。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 引擎与桥接 | `lib.rs` | 装载前端、提供帧/输入接口并绑定 EmbeddedService |
| SDL2 宿主 | `main.rs` | 参数、设备环境、显示选择、事件调度和退出管理 |
| 控制器输入 | `input.rs` | 本地映射优先、SDL 可用映射检查、A/B 和 X/Y 语义交换、缺失映射校准与热插拔 |
| GPU 绘制 | `gpu.rs` | 将图形命令转成 SDL2 绘制并维护纹理缓存 |
