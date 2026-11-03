# 掌机游戏与应用端口

项目的产品适配层：复用根 `_kit/` 和 crates/ 的公共能力，将游戏或应用组成 PortMaster/TrimUI 可部署包。各 manifest 描述包身份、入口与依赖；多数游戏由 Lua 声明设置并经 Shell 模板交给 Unity/Godot，APP Manager 使用独立 Rust/Lua runtime，录屏应用调用生成的采帧 CLI。

## 约束

- 源码在端口目录维护，组装暂存与已核验交付按根目录约定管理；运行时和构建身份由对应构建器生成。
- 原始资源作为显式输入，发行范围以各端口许可及资源说明为准。
- 共享能力位于 `_kit/`/`crates/`，端口只维护游戏差异。
- APP Manager 的 TrimUI APP 入口保留系统匹配的原始圆角方形图标、尺寸与留白，与 PortMaster 封面独立维护，两者不额外叠加作者外框或角标；其他端口的系统启动器封面与应用图标使用 `_kit/artwork/` 的紫猫角底、细边框和圆角遮罩，保留原图尺寸与构图，横竖版角标按短边等比缩放并锚定右下角。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| APP Manager | `appmanager/` | 独立应用/游戏管理、PortMaster 与 Runtime 维护界面 |
| Batomon Showdown | `batomon/` | 使用专用 Godot runtime 运行玩家 PCK |
| D2R NS | `d2r_ns_2g/` | NS 94012 的 2G 适配、安装路径导入与统一交付入口 |
| 余烬灯塔 | `emberward/` | Godot 4.3、六键校准映射和显式 PCK 导出打包 |
| 植物大战僵尸年度版 | `pvz_portable_jenny/` | 自维护 PvZ Portable 引擎入口，始终排除游戏资源和玩家数据 |
| 像素黑神话 | `heishenhua/` | Unity IL2CPP 图形、输入和游戏辅助设置 |
| 空洞骑士 | `hk/` | Unity 设置与视频引导/PlayerPrefs 适配 |
| Screen Recorder | `recorder/` | 独立后台采帧控制和停止后视频合成应用 |
| Slay the Spire 2 | `sts2/` | C# Godot 掌机兼容补丁、资源工具与启动流程 |
| 空洞骑士：丝之歌 | `silksong/` | Unity 6/Rudroid 显示/内存设置、实测效果策略与游戏配置适配 |
| 龙沉异世录 | `sunkendragon/` | 实验性 Unity 移植、玩家资源准备与基线包流程 |
| 泰拉瑞亚 | `terraria/` | 玩家 APK 提取、语言设置和 Unity 启动适配 |
| 吸血鬼幸存者 1.14 | `vampiresurvivors114/` | Unity 6/PAD 游戏的显示、图形兼容与按键适配 |
| Je-Wine | `wine-loongos/` | Jenny Loong 的 Wine 游戏库，按公共组件、机型家族、机型环境和独立游戏适配分层 |
