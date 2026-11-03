# Batomon 运行与打包源码

设备侧 `launcher.sh` 接收 PortMaster 环境并定位玩家 PCK，随后启动专用 Godot；主机侧 `scripts/` 将该入口和 runtime 组成包。`gamedata-README.md` 是唯一随包资源说明，游戏 PCK 不从源码目录自动收集。

## 约束

- PCK 与 Godot 解密/扩展支持必须匹配，源码包不代替玩家准备游戏资源。
- 保留 Wayland/SDL2 与输入助手的生命周期管理。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 游戏入口 | `launcher.sh` | 检查 PCK并管理 Wayland/SDL2、音频与输入助手 |
| 资源说明 | `gamedata-README.md` | 安装后供玩家放置 PCK 的说明 |
| 发行流程 | `scripts/` | 把入口与 Godot 组合为发行负载 |
