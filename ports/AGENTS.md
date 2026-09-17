# 掌机游戏与应用端口

> 按端口组织发行清单、设备入口、设置界面和特定资源准备流程。

## 地位

项目的产品适配层：复用根 `_kit/` 和 crates/ 的公共能力，将游戏或应用组成 PortMaster/TrimUI 可部署包。

## 逻辑

各 manifest 描述包身份、入口与依赖；多数游戏由 Lua 声明设置并经 Shell 模板交给 Unity/Godot，APP Manager 使用独立 Rust/Lua runtime，录屏应用调用生成的采帧 CLI。

## 约束

- 每个端口的源码和生成发行目录分离；dist/、外部 runtime、二进制和本机缓存不手工改写。
- 游戏资源遵守各端口说明与许可边界，玩家输入不可因文档维护被读取、转换或删除。
- 共享能力优先位于 `_kit/`/crates/，本层保留游戏差异；版本变更仍须遵循根 AGENTS.md 的显式授权规则。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| APP Manager | `appmanager/` | 独立应用/游戏管理、PortMaster 与 Runtime 维护界面 |
| Batomon Showdown | `batomon/` | 使用专用 Godot runtime 运行玩家 PCK |
| 像素黑神话 | `heishenhua/` | Unity IL2CPP 图形、输入和游戏辅助设置 |
| 空洞骑士 | `hk/` | Unity 设置与视频引导/PlayerPrefs 适配 |
| Screen Recorder | `recorder/` | 独立后台采帧控制和停止后视频合成应用 |
| Slay the Spire 2 | `sts2/` | C# Godot 掌机兼容补丁、资源工具与启动流程 |
| 空洞骑士：丝之歌 | `silksong/` | Unity 6/Bogodroid 启动设置、帧率/画质/内存选项与游戏配置适配 |
| 龙沉异世录 | `sunkendragon/` | 实验性 Unity 移植、玩家资源准备与基线包流程 |
| 泰拉瑞亚 | `terraria/` | 玩家 APK 提取、语言设置和 Unity 启动适配 |
| 吸血鬼幸存者 1.14 | `vampiresurvivors114/` | Unity 6/PAD 游戏的显示、图形兼容与按键适配 |
