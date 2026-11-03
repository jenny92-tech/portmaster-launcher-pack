# 掌机显示运行时补丁

机型环境选用这里构建的私有 Wine/WSI 组件。Wine 窗口创建前请求全屏并以启动器画面作为临时背景；WSI 的 Wayland 帧回调用每次会话 token 通知启动器完成画面交接。游戏适配仅声明全屏需求，不直接选择 GPU 实现。

## 约束

- 不更改系统 Wine、合成器或 GPU 驱动；只构建私有共享组件。
- 来源、补丁、二进制和目录校验值同时维护；不得只改校验文本。
- 首帧信号使用每次启动的 token，不能把进程存在或固定延迟当作画面就绪。
- 仅对明确启用的 Vulkan/DXVK 会话生效；普通 GDI 游戏不采用启动背景覆盖。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|---|---|---|
| 构建环境 | `Dockerfile.wine` | Wine Unix 驱动的固定构建依赖 |
| 构建记录 | `BUILD.md` | 源码、工具链、配置及验证范围 |
| 启动背景 | `wine_startup_card.h` | 启动器图像尺寸检查与临时背景 |
| Wine 补丁 | `wine-handheld-startup.patch` | Wine 10 原生全屏和背景接入 |
| WSI 补丁 | `wsi-first-frame.patch` | 会话 token 绑定的 Wayland 首帧通知 |
