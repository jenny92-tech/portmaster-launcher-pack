# STS2 移植辅助工具

正式构建入口 optimize_handheld.py 协调本目录的身份校验、资源转换、DLL 注入和主包合并；各子工具也可接收显式输入独立使用。运行时采样和设备传输不属于离线构建链，按下表分别进入，避免把安装动作当成资源处理。

## 约束

- 多数工具消费玩家提供的游戏文件或外部源码，不把这些输入提交或打包分发。
- Windows 原始输入与 Linux 基线分别保留一份于 `gamefiles/sts2/windows/Slay the Spire 2/`、`gamefiles/sts2/linux-baseline/`（仓库根相对路径），或通过必填参数指定其他私有目录；不能将历史构建快照作为隐式输入。
- 构建工具只从显式参数或 PATH 选择 Godot/.NET；转换缓存和合并输出可再生，不承担维护源码或原始输入的保存职责。
- 设备诊断、原位补丁和清理操作必须显式指定并核验目标。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 手持优化入口 | `optimize_handheld.py`、`handheld_low_profile.json` | 已准备输入的计划/构建/部署编排与报告 |
| Windows 游戏准备 | `prepare_windows_game.py`、`handheld_low_v110_profile.json` | 绑定 Windows DLL/deps 及 Linux 基线的 ARM64 托管准备 |
| 运行时内存采样 | `collect_memory_snapshot.py`、`collect_runtime_counters.py` | 设备/进程身份校验后的聚合内存和 .NET 计数 |
| 隔离 VMA 试验入口 | `vma_trial_entry.py` | 仅为固定身份引擎和活动包生成独立 0/32/64 配置试验脚本，不改正式入口 |
| 原生堆跟踪试验入口 | `vma_heap_profile_entry.py` | 在已校验私有入口的最终游戏 exec 注入固定分析器，原始记录仅写独占私有目录 |
| csharp-godot-arm64-kit | `csharp-godot-arm64-kit/` | PE/deps/PCK 补丁与引擎内存分析 |
| device_tools | `device_tools/` | 参数化传输安装、清理及正式入口 helper |
| dll_surgery | `dll_surgery/` | Cecil 注入与结构拒绝边界 |
| TrimUI 旧引擎桥 | `trimui_v110_bridge/` | 固定输入的独立托管回调适配，游戏侧保留官方补丁入口 |
| godot_pck | `godot_pck/` | 纹理/字体转换、合并及游戏专属覆盖 |
| steam_mock | `steam_mock/` | 从 Steam 包装源码生成动态链接符号桩 |
