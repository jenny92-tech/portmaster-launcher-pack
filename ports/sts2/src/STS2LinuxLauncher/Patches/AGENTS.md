# STS2 运行时兼容补丁

由上级 ModEntry 注册的资源覆盖、Harmony 补丁及原生事件处理。MemoryBudget 决定预加载策略，QualityProfile 决定粒子/菜单效果；诊断分别控制内存探针和有界首次出牌计时。

## 约束

- Godot 对象通过反射访问，不引入第二份 GodotSharp 程序集。
- 硬件内存阈值与用户画质偏好是独立策略轴，不相互替代。
- 反射目标缺失时保留现有 best-effort 行为；转场材质需避免共享资源清理造成失效。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| AtlasLazyPatches.cs | `AtlasLazyPatches.cs` | 在低内存设备保留必要图集并按首次使用延迟加载其余图集 |
| 掌机焦点兼容 | `InputFocusPolicy.cs` | 显式开关控制已保留平台覆盖层的窗口焦点回退 |
| 资源生命周期诊断 | `AssetCacheDiagnostics.cs` | 显式启用后记录会话队列、资源类别和非强制 GC 的托管堆估值；可选 Linux glibc mallinfo2 汇总和有上限的 Common 路径 |
| 原生堆回收试验 | `NativeHeapTrim.cs` | 显式启用时核验进程 glibc 分配器，在战斗准备遮罩内仅尝试一次归还完整空闲页 |
| 输入诊断 | `InputDiagnostics.cs` | 显式启用后在首个菜单记录 60 秒窗口焦点、手柄数和事件类别汇总，不记录按键值或消费事件 |
| 首次出牌计时 | `FirstCardTrace.cs` | 显式诊断下记录资源加载、帧间隔及渲染管线计数，最多五分钟后解除帧监听 |
| 纹理诊断桥 | `TextureDiagnosticBridge.cs` | 显式启用时提取并挂载内嵌小 PCK，加载诊断场景；失败不影响渲染准备 |
| 原生渲染准备桥 | `RenderPreparationBridge.cs` | 加载原生渲染适配、在首个主菜单前等待轻量特效预载终态、处理材质/缓存及视觉命中预热 |
| GameSettingsDefaultPatches.cs | `GameSettingsDefaultPatches.cs` | 将启动器语言及一次性节能默认值写入游戏设置 |
| LifecyclePreloadPatches.cs | `LifecyclePreloadPatches.cs` | 为低内存设备跳过启动预加载并保留战斗入口资源加载 |
| MemoryProbePatches.cs | `MemoryProbePatches.cs` | 在调试模式记录资源加载和场景切换的内存压力 |
| MenuDietPatches.cs | `MenuDietPatches.cs` | 隐藏低内存或流畅档菜单背景/Spine 节点并触发设置同步 |
| ParticleDietPatches.cs | `ParticleDietPatches.cs` | 官方运行时经原生 NodeAdded 事件关闭 GPU 发射器并限量 CPU 粒子，保留旧引擎钩子 |
| PlatformPatches.cs | `PlatformPatches.cs` | 跳过掌机端不可用的 Steam 和 Sentry 初始化及数据上传 |
| ShaderCompatibilityPatches.cs | `ShaderCompatibilityPatches.cs` | 官方运行时覆盖同路径 Shader/菜单资源，旧引擎保留动态材质替换 |
| TransitionMaterialPatches.cs | `TransitionMaterialPatches.cs` | 复制共享转场材质以避免缓存清理期间出现已释放对象 |
