# 官方运行时补丁接入

使用 Mono.Cecil 读取玩家提供的 STS2 DLL，在 NGame._EnterTree 开始时调用同目录兼容层，将 GPU 粒子重启/发射调用交给兼容层策略，并在房间、材质与缓存返回点接入原生渲染准备，并为显式低内存模式接入选择性图集加载。输出单独的 DLL，保留输入及官方 Godot；不执行游戏程序集。

## 约束

- 只处理能唯一定位的无参数实例入口及 public static ApplyOfficialRuntime()，重复注入必须拒绝。
- 输出不得覆盖输入；写出后重新读取并验证调用、架构和入口签名。
- inspect 仅打印启动及菜单相关 IL，游戏 DLL 和构建产物不纳入源码。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 补丁工具 | `Program.cs` | 只读检查、诊断资源内嵌 SHA 校验及 VFX 材质 IL 审计、注入入口、低内存图集加载、首个菜单的轻量特效预载门、可选输入诊断、渲染准备和首次出牌/资源计时、路由 GPU 激活、跳过 Windows 专属 DXGI 诊断块、校验缓存驱逐调用者、补齐依赖及写出后验证 |
| 资源诊断注入 | `AssetCacheDiagnosticsHooks.cs` | 验证加载会话构造和完成控制流，接入默认关闭的只读诊断 |
| 焦点策略注入 | `InputFocusHooks.cs` | 验证窗口焦点原始控制流，在平台覆盖层之后接入显式焦点策略 |
| 两语言选择 | `LanguageRestrictionHooks.cs` | 对已核验的游戏 DLL 保留英文与简体中文，写后核验其他方法不变及语言回退边界 |
| 图集策略注入 | `AtlasMemoryHooks.cs` | 检查签名并注入显式低内存的启动和查询图集加载边界 |
| 构建声明 | `official_runtime.csproj` | 固定 Mono.Cecil 依赖和 net9.0 控制台目标 |
