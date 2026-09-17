# Batomon 运行与打包源码

> 保存 Godot 启动入口、玩家数据说明和专用发行流程。

## 地位

Batomon 端口的源码层，区别于仅声明选项的通用 LÖVE 游戏端口。

## 逻辑

发行脚本组装 launcher.sh 与专用 Godot runtime；设备入口读取 PortMaster 环境，检查玩家 PCK 后启动 Godot。

## 约束

- PCK 与 Godot 解密/扩展支持必须匹配，源码包不代替玩家准备游戏资源。
- 保留 Wayland/SDL2 与输入助手的生命周期管理。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 游戏入口 | `launcher.sh` | 配置设备图形/音频/输入并运行玩家 PCK |
| 资源说明 | `gamedata-README.md` | 发行包内玩家 PCK 放置说明 |
| 发行流程 | `scripts/` | 专用 Godot 与启动器包组装，见子目录 AGENTS.md |
