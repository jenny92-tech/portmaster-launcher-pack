# STS2 运行时兼容补丁

这些钩子由 ModEntry 安装，按 MemoryBudget 与 QualityProfile 分别处理资源加载和视觉质量。资源桥把原生 Godot 渲染准备放入场景树；可选诊断只观察加载、输入或帧时序，不承担游戏主流程。

## 约束

- Godot 对象通过反射访问，不引入第二份 GodotSharp 程序集。
- 硬件内存阈值与用户画质偏好是独立策略轴，不相互替代。
- 反射目标缺失时保留现有 best-effort 行为；转场材质需避免共享资源清理造成失效。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| AtlasLazyPatches.cs | `AtlasLazyPatches.cs` | 必要图集保留与其余图集首次访问加载 |
| 掌机焦点兼容 | `InputFocusPolicy.cs` | 平台覆盖层之后的显式窗口焦点回退 |
| 资源生命周期诊断 | `AssetCacheDiagnostics.cs` | 资源会话、非强制 GC 堆估值、可选 glibc 汇总及有界 Common 路径 |
| 原生堆回收试验 | `NativeHeapTrim.cs` | 核验 glibc 后在战斗遮罩内单次尝试归还完整空闲页 |
| 输入诊断 | `InputDiagnostics.cs` | 显式启用后在首个菜单记录 60 秒窗口焦点、手柄数和事件类别汇总，不记录按键值或消费事件 |
| 首次出牌计时 | `FirstCardTrace.cs` | 资源/帧/管线计时，五分钟内解除监听 |
| 纹理诊断桥 | `TextureDiagnosticBridge.cs` | 显式挂载内嵌诊断包，失败不阻断渲染准备 |
| 原生渲染准备桥 | `RenderPreparationBridge.cs` | 场景树接入、主菜单前预载终态和战斗预热 |
| GameSettingsDefaultPatches.cs | `GameSettingsDefaultPatches.cs` | 将启动器语言及一次性节能默认值写入游戏设置 |
| LifecyclePreloadPatches.cs | `LifecyclePreloadPatches.cs` | 为低内存设备跳过启动预加载并保留战斗入口资源加载 |
| MemoryProbePatches.cs | `MemoryProbePatches.cs` | 在调试模式记录资源加载和场景切换的内存压力 |
| MenuDietPatches.cs | `MenuDietPatches.cs` | 隐藏低内存或流畅档菜单背景/Spine 节点并触发设置同步 |
| ParticleDietPatches.cs | `ParticleDietPatches.cs` | 官方运行时经原生 NodeAdded 事件关闭 GPU 发射器并限量 CPU 粒子，保留旧引擎钩子 |
| PlatformPatches.cs | `PlatformPatches.cs` | 跳过掌机端不可用的 Steam 和 Sentry 初始化及数据上传 |
| ShaderCompatibilityPatches.cs | `ShaderCompatibilityPatches.cs` | 官方运行时覆盖同路径 Shader/菜单资源，旧引擎保留动态材质替换 |
| TransitionMaterialPatches.cs | `TransitionMaterialPatches.cs` | 共享转场材质副本与缓存清理隔离 |
