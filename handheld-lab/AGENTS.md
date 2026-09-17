# 通用掌机开发工具

> 统一真实与虚拟 Linux 掌机的观测、操作和证据接口。

## 地位

独立于具体应用的 Controller/Probe 组件，由 lab 等应用评估器复用。

## 逻辑

devtools 调用 Python Controller，通过本地/Docker/SSH/ADB 传输运行 Shell Probe；provider 提供原生设备能力，可按能力路由到 I/O 或调试目标并归档结果。

## 约束

- 不在通用层编码 App Manager 或某固件的业务规则。
- 场景使用参数数组且在首次动作前完整校验，不执行任意拼接的 Shell 片段。
- 不支持的设备能力明确报告；core、trace、广泛日志采集需显式请求。
- CONTEXT.md/README.md 为已有领域与使用说明，初始化不改写这些文档。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 稳定入口 | `devtools` | 启动 Python Controller 的命令行包装 |
| 主机控制器 | `handheld_lab.py` | 传输、能力路由、诊断归档与场景执行 |
| 目标探针 | `agent/` | 低依赖 POSIX 设备 Probe |
| 原生 provider | `helpers/` | Linux 输入、事件和截图工具与构建入口 |
| 回归验证 | `tests/` | 单元、自测和可选容器 E2E |
| 场景数据 | `scenarios/` | 通用控制器场景 JSON |
| 调试工具箱 | `toolbox/` | 按需重型开发和进程调试容器 |
| 使用说明 | `README.md` | 命令、provider、拓扑和设备能力边界 |
| 领域说明 | `CONTEXT.md` | 已有通用掌机工具术语与边界 |
| 忽略规则 | `.gitignore` | 排除本组件的构建和实验产物 |
