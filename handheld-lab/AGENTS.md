# 通用掌机控制与探针

`devtools` 将命令交给主机 Controller，后者通过本地、Docker、SSH 或 ADB 传输调用目标 Probe。Probe 发现原生 provider 并返回能力与结果，应用侧评估器在此基础上组织业务检查。

## 约束

- 通用层维护传输、能力和场景协议，应用及固件业务规则由调用方提供。
- 场景参数采用数组表示，在首次动作前完成全量校验。
- 不支持的能力返回明确结果；core、trace 和广泛日志采集属于显式调试操作。

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
