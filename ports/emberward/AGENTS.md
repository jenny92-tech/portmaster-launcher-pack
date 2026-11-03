# 余烬灯塔启动器

将显式 Godot 4.3 PCK 与已部署的按键和图形适配接入 Pack，不导入游戏工程、玩家档案或运行目录。

## 约束

- 维持 `emberward/conf` 存档位置，不收集 conf、预览工具、缓存或挂载的 runtime。
- Godot/Weston 继续由 PortMaster 管理；共享 WSI 从 `_kit/compat/` 归档读取。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 清单 | `manifest.json` | 独立入口、原目录名和 PortMaster runtime 依赖 |
| 使用说明 | `README.md` | 导出、构建、安装及图形边界 |
| 授权 | `LICENSE` | 启动器与游戏、兼容库的独立授权 |
| 源码 | `src/` | 启动模板、按键和固定负载打包 |
| 回归 | `tests/` | PCK 选择与负载闭集验证 |
| 忽略规则 | `.gitignore` | 生成 dist 和临时组装目录 |
