# STS2 托管兼容层

构建 sts2_compat.dll，供 Godot fork 或经补丁的游戏启动入口调用。官方运行时路径仅接入资源与性能优化，保留平台和存档处理。ModEntry 注册 Patches；PortPaths 读取启动配置；MemoryBudget 与 QualityProfile 分别控制硬件加载和画质策略。

## 约束

- 目标框架为 net9.0；游戏和 Harmony 引用由 CompatReferenceDir 指定，默认 src/refs。
- 不在编译期引用 GodotSharp，也不生成独立 deps/runtimeconfig 以免重复加载 Godot 桥接实例。
- 版本与二进制身份不因文档或内部格式整理自动变更。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| Diag.cs | `Diag.cs` | 为兼容补丁统一控制可选调试输出 |
| MemoryBudget.cs | `MemoryBudget.cs` | 按显式模式与物理内存选择原生全量或低内存加载 |
| ModEntry.cs | `ModEntry.cs` | 自编引擎入口及游戏侧官方运行时性能入口的安装编排 |
| PortPaths.cs | `PortPaths.cs` | 在启动器交接文件和进程环境之间解析移植配置 |
| QualityProfile.cs | `QualityProfile.cs` | 把用户画质偏好映射为粒子与菜单特效策略 |
| Directory.Build.props | `Directory.Build.props` | 游戏与 Harmony 引用目录配置 |
| STS2LinuxLauncher.csproj | `STS2LinuxLauncher.csproj` | 兼容 DLL 的目标框架、程序集引用和输出配置 |
| Patches | `Patches/` | 按平台、资源、显示及调试职责划分的 Harmony 钩子 |
