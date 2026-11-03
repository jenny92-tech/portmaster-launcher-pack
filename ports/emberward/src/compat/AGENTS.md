# 余烬灯塔图形适配

入口脚本为原厂 MiniLoong Mali g13p0 选择本目录的单窗口 EGL 适配，再放入进程私有执行视图。`build-compat.py` 生成 ELF 和身份记录；负载暂存器同时核验源码与 ELF 摘要。Xwayland SHM 入口只提供窗口元数据，不承接 GLES 绘制。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| EGL 源码 | `egl_client_extensions.c` | 客户端扩展、原生窗口句柄及绘制同步适配 |
| EGL 产物 | `loong-egl-compat.so` | 与身份记录匹配的 ARM64 Release 库 |
| 构建身份 | `loong-egl-compat.json` | 源码/ELF SHA 与工具链参数 |
| 许可来源 | `NOTICE.txt` | MIT 许可和原兼容工作来源 |
| Xwayland 入口 | `xwayland-shm.sh` | 窗口元数据会话；游戏仍使用 GLES |
