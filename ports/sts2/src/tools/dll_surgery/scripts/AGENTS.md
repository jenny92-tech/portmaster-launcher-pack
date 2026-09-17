# STS2 离线 IL 补丁

> 通过 Mono.Cecil 生成针对启动问题的修改后程序集。

## 地位

独立于运行时 Harmony 补丁的实验性 DLL 手术脚本。

## 逻辑

脚本读取输入 DLL 和引用目录，定位目标方法或 IL 指令，写入指定输出 DLL 并报告修改情况。

## 约束

- 保留 dotnet-script shebang 与 Mono.Cecil 引用指令位置。
- 执行会改写用户指定程序集；只在明确授权且保留原始输入时运行。
- 不为文档初始化下载 NuGet、运行脚本或生成游戏 DLL。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| patch_sts2_add_trace.csx | `patch_sts2_add_trace.csx` | 为 STS2 启动卡住问题插入 Console 级 IL 追踪 |
| patch_sts2_null_worldenv.csx | `patch_sts2_null_worldenv.csx` | 适配禁用 3D 的 Godot 运行时以绕过不存在的 WorldEnvironment |
| patch_sts2_skip_preload.csx | `patch_sts2_skip_preload.csx` | 以离线 IL 补丁跳过 STS2 批量启动预加载 |

