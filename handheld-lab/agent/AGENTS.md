# 目标端能力探针

`handheld-agent.sh` 是 Controller 流式发送的 POSIX sh 入口。它枚举已安装 provider、输出 TSV 能力表，并按命令分派观测、输入、截图和进程操作。

## 约束

- 保持低依赖和可移植 Shell 语义，能力结果以实际 provider 为准。
- 常规观测采用有界命令；core、trace 和系统日志由显式操作触发。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 探针入口 | `handheld-agent.sh` | 能力发现、设备观测和动作分派 |
