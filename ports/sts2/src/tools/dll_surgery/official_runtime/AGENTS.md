# 官方运行时补丁接入

Mono.Cecil 工具以玩家 STS2 DLL 为输入，在 NGame._EnterTree、GPU 发射调用及房间/材质/缓存返回点接入同目录兼容层。可选低内存、语言和诊断钩子分别验证自己的 IL 控制流；输出 DLL 写后重新读取，整个准备过程不执行游戏代码。

## 约束

- 只处理能唯一定位的无参数实例入口及 public static ApplyOfficialRuntime()，重复注入必须拒绝。
- 输出不得覆盖输入；写出后重新读取并验证调用、架构和入口签名。
- inspect 仅打印启动及菜单相关 IL，游戏 DLL 和构建产物不纳入源码。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 补丁工具 | `Program.cs` | inspect、结构审计、兼容入口/VFX/预载注入与写后总校验 |
| 资源诊断注入 | `AssetCacheDiagnosticsHooks.cs` | 加载会话构造/完成点的默认关闭诊断 |
| 焦点策略注入 | `InputFocusHooks.cs` | 原平台覆盖层之后的焦点策略注入 |
| 两语言选择 | `LanguageRestrictionHooks.cs` | 固定 DLL 的中英闭集、回退及无关方法保持 |
| 图集策略注入 | `AtlasMemoryHooks.cs` | 显式低内存的启动/查询图集钩子 |
| 构建声明 | `official_runtime.csproj` | 固定 Cecil 依赖的 net9.0 控制台工具 |
