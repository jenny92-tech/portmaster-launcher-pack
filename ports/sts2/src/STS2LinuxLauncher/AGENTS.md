# STS2 托管兼容层

Godot fork 或已注入的游戏入口调用 ModEntry，后者安装 Patches 并生成 sts2_compat.dll 的运行行为。PortPaths 读取启动器交接参数；MemoryBudget 决定资源加载方式，QualityProfile 决定视觉策略。官方 runtime 接入只启用资源与性能路径，保留其平台及存档处理。

## 约束

- 目标框架为 net9.0；游戏和 Harmony 引用由 CompatReferenceDir 指定，默认 src/refs。
- 不在编译期引用 GodotSharp，也不生成独立 deps/runtimeconfig 以免重复加载 Godot 桥接实例。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| Diag.cs | `Diag.cs` | 为兼容补丁统一控制可选调试输出 |
| MemoryBudget.cs | `MemoryBudget.cs` | 显式模式与物理内存到资源加载策略 |
| ModEntry.cs | `ModEntry.cs` | 自编引擎/官方 runtime 两类补丁安装入口 |
| PortPaths.cs | `PortPaths.cs` | 交接文件及环境到兼容配置的解析 |
| QualityProfile.cs | `QualityProfile.cs` | 画质偏好到菜单/粒子策略 |
| Directory.Build.props | `Directory.Build.props` | 游戏与 Harmony 引用目录配置 |
| STS2LinuxLauncher.csproj | `STS2LinuxLauncher.csproj` | net9.0 DLL、引用与构建输出 |
| Patches | `Patches/` | 由 ModEntry 注册的资源、平台和诊断钩子 |
