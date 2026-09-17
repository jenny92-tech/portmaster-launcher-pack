# STS2 移植辅助工具

> 汇集资源处理、程序集改写和原生平台诊断工具。

## 地位

与正式启动器和兼容 DLL 分离的构建/调试工具入口。

## 逻辑

godot_pck 负责纹理和资源覆盖；csharp-godot-arm64-kit 处理跨架构兼容；dll_surgery 保存离线 IL 实验；steam_mock 生成原生接口桩。

## 约束

- 多数工具消费玩家提供的游戏文件或外部源码，不把这些输入提交或打包分发。
- 设备诊断、原位补丁和带清理的构建需独立核验目标，不因阅读文档而执行。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| csharp-godot-arm64-kit | `csharp-godot-arm64-kit/` | C#/.NET、PE/PCK 与 EGL 的跨架构诊断和补丁 |
| dll_surgery | `dll_surgery/` | Mono.Cecil 离线启动链路实验 |
| godot_pck | `godot_pck/` | 纹理重导入、资源覆盖与游戏专属构建 |
| steam_mock | `steam_mock/` | 从 Steam 包装源码生成动态链接符号桩 |

