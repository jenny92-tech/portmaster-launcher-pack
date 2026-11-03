# Batomon 发行组装

`_kit/dist_port.sh batomon` 调用本目录的构建器。它重建端口 dist，内联启动器、暂存 PortKit 辅助程序并复制 `GODOT_BIN` 为 `godot.mono`，最后生成 PortMaster 元数据和最终负载身份。

## 约束

- `GODOT_BIN` 必须具备 Batomon 分支的 Steam 桩和 PCK 解密支持；普通 Godot 不能仅凭文件名替代。游戏 PCK 由玩家另行准备。
- 脚本会清空发行目录，重建前确认其中不含唯一输入。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 打包入口 | `dist-port.sh` | GODOT_BIN → godot.mono、入口、资源说明及 build-info |
