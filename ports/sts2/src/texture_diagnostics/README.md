# 独立资源诊断

通过既有 `SLL_TEXTURE_DIAG=1` 桥加载独立 PCK。常规纹理扫描仍为每 20 秒最多 12 次；另以每 30 秒最多 20 次记录 `[RESOURCE-STATS]`，两组独立，均结束后自动释放入口。未启用桥时不执行。UI 观察与测试点击另有隔离目录及显式开关约束，见目录说明。

仅隔离测试启用的鼠标请求使用根 viewport 逻辑坐标，经其 final transform 转为窗口坐标，带窗口 ID 调用 `Input.parse_input_event`；按下和释放跨帧，事件只发送一次，以同步 Godot 鼠标状态。

Vulkan 且主 RenderingDevice 存在时，`rendering_device` 读取 `Performance.RENDER_VIDEO_MEM_USED`、`RENDER_TEXTURE_MEM_USED`、`RENDER_BUFFER_MEM_USED` 的上一帧缓存，单位字节；非 Vulkan、无设备、无效或尚未更新的零值报告有限的 `unavailable` 原因。Godot 4.5.1 Vulkan `VIDEO` 来自 VMA `allocationBytes`，不是分配器 `blockBytes`、物理驻留或 RSS；纹理和 buffer 数值为独立引擎计数，不能将它们和总数机械相减后归因。帧缓存会有延迟或精度限制。

FMOD 仅当 Engine 的 `FmodServer` 与返回的 `FmodPerformanceData` 为无脚本的精确原生类且相应方法已由 ClassDB 注册时，读取其现有 `currently_allocated`、`max_allocated` 缓存（字节）。未知类、缺方法、负值、不一致或尚未确认的零值报告 `unavailable`；不会调用 FMOD init、update、阻塞统计或加载 bank。该数值可能与进程内存统计重叠，不能直接相加。上游插件中的数据来源与实际设备二进制需分别核验。

Godot 对应实现：[RD 计数缓存](https://github.com/godotengine/godot/blob/4.5.1-stable/servers/rendering/renderer_rd/storage_rd/utilities.cpp#L276)、[Vulkan VMA allocationBytes](https://github.com/godotengine/godot/blob/4.5.1-stable/drivers/vulkan/rendering_device_driver_vulkan.cpp#L5266)；FMOD 插件对应实现：[性能缓存](https://github.com/utopia-rise/fmod-gdextension/blob/fda1f89/src/fmod_server.cpp#L864)。
