# STS2 设备传输与补丁清理

构建后的安装器通过显式目标传输和激活已校验产物；清理器默认只读预检。正式启动器只调用设备准入、后端/显示交接及有界日志 helper，不会经这些安装器启动游戏。上传与下载保留独立续传状态，不能互换会话目录。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| v0.110.1 安装与清理 | `install_v110.py`、`upload_build.py`、`cleanup_v110_legacy.py`、`cleanup_v110_bundle.py` | 0.110.1 上传/本地复制、选择器切换与精确旧包清理 |
| 运行时架构和身份 | `managed_dll_arch.py`、`runtime_baseline_v110.json` | AnyCPU/ARM64/ReadyToRun 格式及基线摘要 |
| 安装低纹理构建 | `install_handheld.py` | 计划、续传、设备合并和有序激活 |
| 渲染与日志 | `sts2_trimui_backend.py`、`sts2_bounded_log.py` | 正式 GLES/Vulkan、Weston 会话与有界日志 |
| 设备准入及显示交接 | `sts2_official_profile.py`、`sts2_trimui_lease.py` | 设备身份门禁和已识别前端的显示交接 |
| 上传纹理 | `upload_texture.py` | 来源所有权、分块前缀和拒绝覆盖的上传 |
| 下载文件 | `download_resumable.py` | 断点校验、大小绑定和本机发布 |
| 清理旧补丁 | `cleanup_patch.py` | 精确旧补丁的清单/fd/maps 检查；--apply 才删除 |

`cleanup_patch.py` 在目标设备上直接执行。对根目录的其他挂载别名须逐个传入 `--path-alias`，以便检查进程引用；执行前应确保没有并发进程启动或修改补丁。工具只检查精确选定的旧补丁，不执行广泛清理。

上传的 `--state-dir` 必须在续传时保持不变；初始远端创建完成但本机 inode 状态未持久化时会故障关闭，需人工核验后处理遗留文件。
