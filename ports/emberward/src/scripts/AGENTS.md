# 余烬灯塔构建

通过共享 dist 调度生成包；使用固定文件清单，构建不访问设备或自动寻找 PCK。

## 约束

- 维持 `emberward/conf` 存档位置，不收集 conf、预览工具、缓存或挂载的 runtime。
- Godot/Weston 继续由 PortMaster 管理；共享 WSI 从 `_kit/compat/` 归档读取。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 标准构建 | `dist-port.sh` | 调度 assemble、负载、清单及构建身份 |
| 固定负载 | `stage-payload.py` | 校验 EGL/共享 WSI 并可选加入显式 PCK |
| EGL 重建 | `build-compat.py` | ARM64 Release 构建及真实身份记录 |
