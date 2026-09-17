# Godot 显示链路预设

> 为同一 Godot POC 二进制提供不同显示和 GL 查询实验。

## 地位

ARM64 移植工具中的设备诊断启动器集合。

## 逻辑

01–12 调整 POC_* 环境开关；20–28 通过 shim_egl.so 追踪或屏蔽查询；各预设将日志写到设备 poc_sdl2 目录。

## 约束

- 19 份带 Template 生成说明的预设（01–12、21–25、27–28）为生成快照，分形头注释仅维护两份模板及手写 20/26 入口。
- 这些入口依赖实验版 Godot 对 POC_* 的支持；dummy 显示和 --verbose 不代表正式启动策略。
- 不要在工作站执行设备实验或自动部署、清理设备缓存。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| README.md | `README.md` | 预设分类、部署方式与日志路径说明 |
| _template_inline.sh | `_template_inline.sh` | 按预设名与 POC_* 环境开关生成实验入口的模板 |
| _blacklist_template.sh | `_blacklist_template.sh` | 按预设名与 EGL 函数黑名单生成实验入口的模板 |
| [POC]01-default.sh | `[POC]01-default.sh` | 已生成的无额外 POC 开关基线快照 |
| [POC]02-no_master.sh | `[POC]02-no_master.sh` | 已生成的关闭 DRM master 获取预设 |
| [POC]03-argb_a8.sh | `[POC]03-argb_a8.sh` | 已生成的 ARGB/8 位 alpha 格式预设 |
| [POC]04-gbm_linear.sh | `[POC]04-gbm_linear.sh` | 已生成的 GBM 线性缓冲预设 |
| [POC]05-no_plat_ext.sh | `[POC]05-no_plat_ext.sh` | 已生成的禁用 EGL platform 扩展预设 |
| [POC]06-no_depth.sh | `[POC]06-no_depth.sh` | 已生成的无深度缓冲预设 |
| [POC]07-gles2.sh | `[POC]07-gles2.sh` | 已生成的 GLES2/16 位深度预设 |
| [POC]08-skip_pageflip.sh | `[POC]08-skip_pageflip.sh` | 已生成的跳过翻页与垂直同步等待预设 |
| [POC]09-skip_makecurrent.sh | `[POC]09-skip_makecurrent.sh` | 已生成的跳过 EGL make-current 预设 |
| [POC]10-skip_surface.sh | `[POC]10-skip_surface.sh` | 已生成的跳过 EGL surface 创建预设 |
| [POC]11-skip_egl.sh | `[POC]11-skip_egl.sh` | 已生成的跳过 EGL 初始化预设 |
| [POC]12-skip_kms.sh | `[POC]12-skip_kms.sh` | 已生成的跳过 KMS 初始化预设 |
| [POC]20-shim.sh | `[POC]20-shim.sh` | 加载 EGL 诊断垫片而不设置函数黑名单 |
| [POC]21-block_compute.sh | `[POC]21-block_compute.sh` | 已生成的屏蔽 compute/内存屏障函数预设 |
| [POC]22-block_multiview.sh | `[POC]22-block_multiview.sh` | 已生成的屏蔽 OVR multiview 函数预设 |
| [POC]23-block_khr_debug.sh | `[POC]23-block_khr_debug.sh` | 已生成的屏蔽 KHR 调试接口预设 |
| [POC]24-block_storage3d_multi.sh | `[POC]24-block_storage3d_multi.sh` | 已生成的屏蔽多重采样存储函数预设 |
| [POC]25-block_aggressive.sh | `[POC]25-block_aggressive.sh` | 已生成的组合屏蔽常见可疑函数预设 |
| [POC]26-shim_full_strace.sh | `[POC]26-shim_full_strace.sh` | 结合 EGL 垫片与完整 strace 的诊断入口 |
| [POC]27-block_31_compute.sh | `[POC]27-block_31_compute.sh` | 已生成的屏蔽 GLES3.1 compute/间接绘制等函数预设 |
| [POC]28-block_all_31_32.sh | `[POC]28-block_all_31_32.sh` | 已生成的广泛屏蔽 GLES3.1/3.2 函数预设 |

