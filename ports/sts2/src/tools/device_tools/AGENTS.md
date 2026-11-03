# STS2 设备传输与补丁清理

参数化安装与传输工具要求显式目标和经过校验的输入，安装可切换构建选择但不启动游戏；清理默认只读预检。运行时 helper 供正式启动器调用。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| v0.110.1 安装与清理 | `install_v110.py`、`upload_build.py`、`cleanup_v110_legacy.py`、`cleanup_v110_bundle.py` | 断点上传或本地复制并绑定单一新版选择器，核验使用状态后精确清理旧试验 |
| 运行时架构和身份 | `managed_dll_arch.py`、`runtime_baseline_v110.json` | 检查 AnyCPU/ARM64 运行时格式并绑定已验证设备运行库摘要 |
| 安装低纹理构建 | `install_handheld.py` | 显式设备目标，验证并续传、设备端合并与有序激活；计划只读 |
| 渲染与日志 | `sts2_trimui_backend.py`、`sts2_bounded_log.py` | 正式启动器的 GLES/Vulkan 选择、独立 Weston 会话和有界日志 |
| 设备准入及显示交接 | `sts2_official_profile.py`、`sts2_trimui_lease.py` | 已验设备指纹与 Vulkan 依赖门禁，仅交接已识别前端并恢复显示 |
| 上传纹理 | `upload_texture.py` | 指定 ADB 序列号、远端目录、纹理、构建报告和主机持久状态目录，验证所有权与分块前缀后续传并拒绝覆盖 |
| 下载文件 | `download_resumable.py` | 指定 ADB 序列号、源路径和大小、本机目标及报告，校验断点并安全发布 |
| 清理旧补丁 | `cleanup_patch.py` | 指定根目录及旧/当前补丁身份，验证清单和进程 fd/maps；默认 dry-run，`--apply` 才删除 |

`cleanup_patch.py` 在目标设备上直接执行。对根目录的其他挂载别名须逐个传入 `--path-alias`，以便检查进程引用；执行前应确保没有并发进程启动或修改补丁。工具只检查精确选定的旧补丁，不执行广泛清理。

上传的 `--state-dir` 必须在续传时保持不变；初始远端创建完成但本机 inode 状态未持久化时会故障关闭，需人工核验后处理遗留文件。
