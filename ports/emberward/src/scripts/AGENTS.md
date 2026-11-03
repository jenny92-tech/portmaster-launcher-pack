# 余烬灯塔构建

共享 dist 入口调用 `dist-port.sh`，再由 `stage-payload.py` 复制固定负载。暂存器检查 EGL 源码/产物和共享 WSI 的摘要，只从显式参数接收 PCK；兼容库重建独立由 `build-compat.py` 负责。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 标准构建 | `dist-port.sh` | 内联入口并生成 port.json、最终负载身份 |
| 固定负载 | `stage-payload.py` | 校验 EGL/WSI 身份、写进程开关并选择 PCK |
| EGL 重建 | `build-compat.py` | 构建 ARM64 Release EGL 库及摘要记录 |
