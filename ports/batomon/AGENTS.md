# Batomon 端口

> 为玩家准备的 Batomon Showdown Demo PCK 提供 Godot 掌机运行包。

## 地位

ports/ 下使用专用 Godot SDL2 构建的游戏端口。

## 逻辑

manifest 指向 src/ 的启动器；专用打包脚本复制 Godot runtime 和说明，设备端读取玩家 PCK 后运行游戏。

## 约束

- 不分发玩家游戏 PCK；用户提供与 runtime 匹配的资源。
- Godot、Steam 扩展与解密支持需成套匹配；dist/ 是生成目录，不直接维护源码文档。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | Godot runtime、入口、目标设备和资源约束 |
| 使用说明 | `README.md` | 游戏资源准备和部署说明 |
| 授权 | `LICENSE` | 端口授权声明 |
| 启动与打包 | `src/` | Shell 运行入口和发行组装，见子目录 AGENTS.md |
