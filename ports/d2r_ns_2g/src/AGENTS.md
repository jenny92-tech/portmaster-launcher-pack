# D2R NS 运行入口

执行链为 `launcher.sh → launch.py → run-game.sh`：可见入口选择安装 JSON，Python 按 FIELDS 校验完整绝对路径，再通过环境变量交给 Bash。runner 独立处理 `--check` 和实际会话，路径清单始终作为数据使用。

## 约束

- 路径清单包含完整绝对路径，作为数据传递，原 profile 位置保持不变。
- `--check` 只核验所需文件，不创建 profile 或启动 runtime；实际会话才取得档案锁。runtime、模块和资源必须与准备流程匹配。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 启动入口 | `launcher.sh` | 定位 install-paths.json，透传启动参数 |
| 路径验证 | `launch.py` | load_paths 校验字段后以 execve 交接 runner |
| 游戏运行 | `run-game.sh` | 文件预检或 C197 会话、存档锁、输入与退出恢复 |
| 运行许可 | `licenses/` | D2R Linux MIT 声明 |
| 打包工具 | `scripts/` | 导入外部路径并组装不含游戏的负载 |
