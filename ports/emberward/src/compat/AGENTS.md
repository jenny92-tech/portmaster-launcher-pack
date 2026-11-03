# 余烬灯塔图形适配

原厂 MiniLoong Mali g13p0 的单窗口 EGL 适配；运行时由启动脚本选入私有执行目录。

## 约束

- 维持 `emberward/conf` 存档位置，不收集 conf、预览工具、缓存或挂载的 runtime。
- Godot/Weston 继续由 PortMaster 管理；共享 WSI 从 `_kit/compat/` 归档读取。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| EGL 源码 | `egl_client_extensions.c` | 保留客户端平台扩展、窗口句柄和逐次绘制同步 |
| EGL 产物 | `loong-egl-compat.so` | 由当前源码真实重建的 ARM64 Release ELF |
| 构建身份 | `loong-egl-compat.json` | 源码、ELF 散列与工具链参数 |
| 许可来源 | `NOTICE.txt` | MIT 许可和原兼容工作来源 |
| Xwayland 入口 | `xwayland-shm.sh` | 仅用 SHM 提供窗口元数据，游戏继续 GLES |
