# LOVE-lite 的 SDL 宿主与服务桥

`main.rs` 在 SDL 初始化前准备映射与显示环境，创建 Engine 和 EmbeddedService；事件驱动 Lua 更新与重绘。`input.rs` 负责控制器语义，`gpu.rs` 将可支持的图形命令提交给 SDL，其他帧沿软件缓冲呈现。

## 约束

- 能力范围是 APP Manager 的 Lua 5.1/LÖVE 子集，不能替代游戏使用的 LÖVE 11.5；SDL 入口受 `sdl-backend` 控制，保留软件回退和空闲按需重绘。
- APP 输入归 SDL 宿主所有，不叠加 gptokeyb。映射按随包通用库、正式解析的 PortMaster 库、APP 私有校准依次加载，后者优先；共享库只读，PortMaster 缺失时仍可独立运行。
- 初始化前调用 `prepare_mapping_hint`，将父进程 SDL 映射降为普通回退，清除本进程 hint 的高优先级；不改父进程、磁盘共享库，也不执行 control.txt/get_controls。
- 只有 SDL 缺少基础方向或动作映射才自动校准，不以随包 GUID 白名单排除已有可用映射。有效重连关闭断开提示；手动校准从设置/Home/F2 发起，不使用任意双键长按。
- 校准结果只写 APP state。`pam_input_layout` 的 A/B、X/Y 交换只作用于 APP 语义，改变布局须等待已按键释放；采集校准仍使用原始标记，不能改写映射文件。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 引擎与桥接 | `lib.rs` | 装载前端、提供帧/输入接口并绑定 EmbeddedService |
| SDL2 宿主 | `main.rs` | 参数、设备环境、显示选择、事件调度和退出管理 |
| 控制器输入 | `input.rs` | 本地映射优先、SDL 可用映射检查、A/B 和 X/Y 语义交换、缺失映射校准与热插拔 |
| GPU 绘制 | `gpu.rs` | 将图形命令转成 SDL2 绘制并维护纹理缓存 |
