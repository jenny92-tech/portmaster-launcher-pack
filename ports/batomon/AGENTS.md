# Batomon 端口

Batomon 通过专用 Godot SDL2 runtime 直接运行玩家 PCK，不经过通用 LÖVE 设置页。共享 dist 调度进入 `src/scripts/`，打包启动器、runtime 和资源放置说明；安装后由 `src/launcher.sh` 检查 PCK 并建立图形和输入环境。

## 约束

- 不分发玩家游戏 PCK；用户提供与 runtime 匹配的资源。
- Godot、Steam 扩展与解密支持需成套匹配。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | runtime、设备范围及玩家资源要求 |
| 使用说明 | `README.md` | 匹配资源的准备与部署步骤 |
| 授权 | `LICENSE` | 端口授权声明 |
| 启动与打包 | `src/` | PCK 检查、游戏启动和专用 runtime 组装 |
