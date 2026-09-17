# EGL 查询诊断垫片

> 截获 EGL/GL 查询以追踪 Mali 驱动初始化。

## 地位

由 POC 启动器通过 LD_PRELOAD 注入的 native 调试工具。

## 逻辑

通过 dlsym(RTLD_NEXT) 转发函数，在 stderr/可选日志中记录查询；匹配 EGL_SHIM_BLACKLIST 时将函数查询结果置空。

## 约束

- 仅用于 Linux ARM64 设备调试，依赖 libdl 与设备图形库。
- 源码与已有 .so 分开管理；文档变更不重建或替换二进制。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| shim_egl.c | `shim_egl.c` | 通过 LD_PRELOAD 记录并按黑名单屏蔽 Mali GL 函数查询 |
| README.md | `README.md` | 垫片用途、设备使用方式和构建说明 |
| shim_egl.so | `shim_egl.so` | 已有设备端诊断动态库产物 |

