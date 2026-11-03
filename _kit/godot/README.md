# Godot 性能浮层

`addons/portkit_performance/` 是 Godot 4 的独立 GDScript 小插件，复用 Godot 内置性能指标。将该目录复制到目标项目的 `res://addons/portkit_performance/`；支持 Godot 4.3/4.5，不支持 Godot 3，也不需要 C#、原生库、纹理或外部命令。

普通项目可在项目设置的 Plugins 中启用 PortKit Performance：插件只在同名 autoload 不存在时添加自己的 autoload。也可不用编辑器插件，在运行时从已进入树的节点调用：

```gdscript
preload("res://addons/portkit_performance/overlay.gd").install(get_tree())
```

安装到场景树根节点，重复调用返回同一个节点，场景切换和暂停期间保留。不要同时使用其他同名的 `PortKitPerformance` 节点；名称被占用时安装返回 `null`。若从根节点正在添加子节点的回调安装，应使用 `call_deferred` 延后调用。已有 C# 入口可通过现有的 GDScript 启动脚本调用这一行，无须重新编译 C#。启用编辑器插件的 autoload 与运行时安装任选其一。

默认隐藏。启动进程设置 `PORTKIT_PERF_OVERLAY=1` 可初始显示，例如 PortMaster 启动脚本中给游戏进程设置该环境变量。运行时返回的节点提供 `set_enabled(true/false)` 和 `toggle()`。项目可以自行在 Input Map 添加 `portkit_perf_toggle` 并映射按键；插件不注册默认按键、不消费事件，宿主应避免与游戏操作冲突。隐藏时停止逐帧采样，显示时文字约每半秒更新，RSS 约每秒读取一次；暂停游戏时仍采样。

显示口径：

- FPS 使用 Godot 的帧率；Frame 是通过单调时钟测量的显示更新周期内平均帧间隔，并非 CPU 时间、GPU 时间或网络延迟。
- RSS 是 Linux/Android `/proc/self/status` 的 `VmRSS`，单位 MiB，包含该进程中的 .NET 和原生内存；共享驻留页也计入，既不是 PSS 也不是进程独占内存。无法读取或其他系统显示 N/A。
- Engine 是 Godot 的 `Performance.MEMORY_STATIC`；该统计在 release 构建不可用，显示 N/A，且不是进程总 RAM。
- TEX 是 Godot 的 `Performance.RENDER_TEXTURE_MEM_USED` 纹理内存统计估计，受后端和驱动限制，并非完整视频内存或专用显存。在统一内存设备上，图形内存可能与系统内存共享；不可将此数与 RSS 简单相加。
- 最后两行是运行时可用的实际渲染方法、驱动与 GPU 名称；老版本 API 不提供或无头运行时显示 N/A，不根据启动参数猜测。

参考 [Godot Performance 文档](https://docs.godotengine.org/en/4.5/classes/class_performance.html) 和 [RenderingServer 文档](https://docs.godotengine.org/en/4.5/classes/class_renderingserver.html)。内置计数器本身可能延迟更新；指标用于观察而非精密分析。
