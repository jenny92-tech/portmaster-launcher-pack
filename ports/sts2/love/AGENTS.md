# STS2 启动器界面

> 声明 STS2 设置项并将选项交给游戏启动阶段。

## 地位

本移植的 LÖVE 前端与 PortMaster 启动模板入口。

## 逻辑

main.lua 使用共享 launcher 定义字段；模板调用共享 UI 后读取交接选项、同步游戏设置及程序集，再启动 Godot SDL2。

## 约束

- 共享界面通过 _kit 组装，不在本目录复制共享逻辑。
- LÖVE 与游戏的显示环境分离；游戏阶段不使用 gptokeyb 抓取输入，也不传 --verbose。
- 玩家已有存档只同步明确指定的设置；游戏文件由玩家提供。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| main.lua | `main.lua` | STS2 的语言、画质与按键交换设置声明 |
| launcher.sh.template | `launcher.sh.template` | 隔离 LÖVE 界面与 SDL2 游戏阶段的 STS2 启动模板 |

