# STS2 运行时兼容补丁

> 按硬件能力和用户选项适配游戏加载、显示与平台服务。

## 地位

由上级 ModEntry 按序注册的 Harmony 补丁集合。

## 逻辑

反射定位游戏方法并安装前后置钩子；MemoryBudget 决定预加载策略，QualityProfile 决定粒子/菜单效果，Diag 控制内存探针。

## 约束

- Godot 对象通过反射访问，不引入第二份 GodotSharp 程序集。
- 硬件内存阈值与用户画质偏好是独立策略轴，不相互替代。
- 反射目标缺失时保留现有 best-effort 行为；转场材质需避免共享资源清理造成失效。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| AtlasLazyPatches.cs | `AtlasLazyPatches.cs` | 在低内存设备保留必要图集并按首次使用延迟加载其余图集 |
| GameSettingsDefaultPatches.cs | `GameSettingsDefaultPatches.cs` | 将启动器语言及一次性节能默认值写入游戏设置 |
| LifecyclePreloadPatches.cs | `LifecyclePreloadPatches.cs` | 为低内存设备跳过启动预加载并保留战斗入口资源加载 |
| MemoryProbePatches.cs | `MemoryProbePatches.cs` | 在调试模式记录资源加载和场景切换的内存压力 |
| MenuDietPatches.cs | `MenuDietPatches.cs` | 隐藏低内存或流畅档菜单背景/Spine 节点并触发设置同步 |
| ParticleDietPatches.cs | `ParticleDietPatches.cs` | 按画质档位限制新加入节点树中的粒子发射数量 |
| PlatformPatches.cs | `PlatformPatches.cs` | 跳过掌机端不可用的 Steam 和 Sentry 初始化及数据上传 |
| ShaderCompatibilityPatches.cs | `ShaderCompatibilityPatches.cs` | 挂载覆盖包并将节点材质替换为 Mali 友好的着色器 |
| TransitionMaterialPatches.cs | `TransitionMaterialPatches.cs` | 复制共享转场材质以避免缓存清理期间出现已释放对象 |

