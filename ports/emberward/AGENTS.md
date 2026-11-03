# 余烬灯塔启动器

余烬灯塔将显式导出的 Godot 4.3 PCK 接入已适配的 MiniLoong 图形和按键环境。源码维护入口、gptk 与小型兼容库；专用构建器从固定清单组包，不复制游戏工程或来源运行目录。

## 约束

- 维持 `emberward/conf` 存档位置，不收集 conf、预览工具、缓存或挂载的 runtime。
- Godot/Weston 继续由 PortMaster 管理；共享 WSI 从 `_kit/compat/` 归档读取。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 清单 | `manifest.json` | 独立入口、原目录名和 PortMaster runtime 依赖 |
| 使用说明 | `README.md` | 导出、构建、安装及图形边界 |
| 授权 | `LICENSE` | 启动器、游戏和兼容库的分别授权 |
| 源码 | `src/` | 启动模板、六通道映射与已绑定身份的图形适配 |
| 回归 | `tests/` | 合成 PCK 及固定负载边界 |
| 忽略规则 | `.gitignore` | 生成 dist 和临时组装目录 |
