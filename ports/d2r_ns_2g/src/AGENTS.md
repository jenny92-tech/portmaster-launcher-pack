# D2R NS 2G 启动源码

可见入口把 JSON 路径作为数据交给 Bash runner，保持 C197 参数和独立 rk3566-2gb 档案路径。

## 约束

- 保留来源安装的 profile 路径；不得改用其他 D2R 端口的档案。
- 2G 是预设身份，不代表已经完成 2 GB 硬件验收；只接收已准备的匹配 Release runtime。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 可见入口 | `launcher.sh` | 标准 SH 跳转并透传只读检查参数 |
| 路径桥接 | `launch.py` | 校验完整绝对路径并 exec runner |
| 游戏执行 | `run-game.sh` | 沿用 C197 的资源、输入、退出与异常日志策略 |
| 运行授权 | `licenses/` | 保留 D2R Linux MIT 许可 |
| 构建 | `scripts/` | 只解析外部已准备入口并生成标准 dist |
