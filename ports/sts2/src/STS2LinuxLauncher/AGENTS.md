# STS2 托管兼容层

> 在游戏 .NET 运行时中安装掌机兼容补丁。

## 地位

构建 sts2_compat.dll，供 Godot fork 在加载游戏前后调用。

## 逻辑

ModEntry 安装程序集解析回退并注册 Patches；PortPaths 读取启动配置；MemoryBudget 与 QualityProfile 分别控制硬件加载和画质策略。

## 约束

- 目标框架为 net9.0；游戏和 Harmony 引用由 CompatReferenceDir 指定，默认 src/refs。
- 不在编译期引用 GodotSharp，也不生成独立 deps/runtimeconfig 以免重复加载 Godot 桥接实例。
- 版本与二进制身份不因文档或内部格式整理自动变更。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| Diag.cs | `Diag.cs` | 为兼容补丁统一控制可选调试输出 |
| MemoryBudget.cs | `MemoryBudget.cs` | 按物理内存决定原生全量加载或低内存延迟加载 |
| ModEntry.cs | `ModEntry.cs` | 供 Godot fork 调用的兼容程序集入口与补丁安装编排 |
| PortPaths.cs | `PortPaths.cs` | 在启动器交接文件和进程环境之间解析移植配置 |
| QualityProfile.cs | `QualityProfile.cs` | 把用户画质偏好映射为粒子与菜单特效策略 |
| Directory.Build.props | `Directory.Build.props` | 游戏与 Harmony 引用目录配置 |
| STS2LinuxLauncher.csproj | `STS2LinuxLauncher.csproj` | 兼容 DLL 的目标框架、程序集引用和输出配置 |
| Patches | `Patches/` | 按平台、资源、显示及调试职责划分的 Harmony 钩子 |

