# STS2 移植辅助工具

与正式启动器和兼容 DLL 分离的构建/调试工具入口。godot_pck 负责纹理和资源覆盖；csharp-godot-arm64-kit 处理跨架构兼容与内存分析；dll_surgery 提供已审离线 IL 适配；steam_mock 生成原生接口桩。

## 约束

- 多数工具消费玩家提供的游戏文件或外部源码，不把这些输入提交或打包分发。
- Windows 原始输入与 Linux 基线分别保留一份于 `gamefiles/sts2/windows/Slay the Spire 2/`、`gamefiles/sts2/linux-baseline/`（仓库根相对路径），或通过必填参数指定其他私有目录；不能将历史构建快照作为隐式输入。
- 构建工具只从显式参数或 PATH 选择 Godot/.NET；转换缓存和合并输出可再生，不承担维护源码或原始输入的保存职责。
- 设备诊断、原位补丁和清理操作必须显式指定并核验目标。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 手持优化入口 | `optimize_handheld.py`、`handheld_low_profile.json` | 离线扫描、身份门禁、纹理与特效构建、程序集注入、主包合并和构建报告 |
| Windows 游戏准备 | `prepare_windows_game.py`、`handheld_low_v110_profile.json` | 锁定新版纯 IL、依赖及 Linux runtime 身份并生成 ARM64 托管输入 |
| 运行时内存采样 | `collect_memory_snapshot.py`、`collect_runtime_counters.py` | 校验设备与进程身份，采集进程/系统聚合快照和有界 .NET 计数，不获取堆内容 |
| 隔离 VMA 试验入口 | `vma_trial_entry.py` | 仅为固定身份引擎和活动包生成独立 0/32/64 配置试验脚本，不改正式入口 |
| 原生堆跟踪试验入口 | `vma_heap_profile_entry.py` | 在已校验私有入口的最终游戏 exec 注入固定分析器，原始记录仅写独占私有目录 |
| csharp-godot-arm64-kit | `csharp-godot-arm64-kit/` | C#/.NET、PE/PCK 与 EGL 的跨架构诊断和补丁 |
| device_tools | `device_tools/` | 参数化安装/传输、默认只读清理，以及正式启动器的设备/显示/日志 helper |
| dll_surgery | `dll_surgery/` | Mono.Cecil 离线启动链路适配与结构门禁 |
| TrimUI 旧引擎桥 | `trimui_v110_bridge/` | 固定输入的独立托管回调适配，游戏侧保留官方补丁入口 |
| godot_pck | `godot_pck/` | 纹理重导入、资源覆盖与游戏专属构建 |
| steam_mock | `steam_mock/` | 从 Steam 包装源码生成动态链接符号桩 |
