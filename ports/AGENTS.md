# 掌机游戏与应用端口

端口是共享能力到具体产品的装配层。`_kit/dist_port.sh` 读取各端口 manifest，选择专用构建器或共享模板流程；生成的入口再把设置和资源路径交给 Unity、Godot 或独立应用运行时。先按下表进入产品目录，再沿其源码导航定位启动、资源准备或打包接口。

## 约束

- 原始资源作为显式输入，发行范围以各端口许可及资源说明为准。
- 设备策略和共享生命周期由 `_kit/`、`crates/` 提供；端口只声明产品差异，manifest、入口和包内布局须一致。
- APP Manager 的 TrimUI APP 入口保留系统匹配的原始圆角方形图标、尺寸与留白，与 PortMaster 封面独立维护，两者不额外叠加作者外框或角标；其他端口的系统启动器封面与应用图标使用 `_kit/artwork/` 的紫猫角底、细边框和圆角遮罩，保留原图尺寸与构图，横竖版角标按短边等比缩放并锚定右下角。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| APP Manager | `appmanager/` | LOVE-lite 管理界面、原生事务与游戏交接 |
| Batomon Showdown | `batomon/` | 使用专用 Godot runtime 运行玩家 PCK |
| D2R NS | `d2r_ns_2g/` | 唯一 NS 发行配置：94012 经典 2G 路径导入 |
| 余烬灯塔 | `emberward/` | Godot 4.3、六键校准映射和显式 PCK 导出打包 |
| 植物大战僵尸年度版 | `pvz_portable_jenny/` | 自维护 PvZ Portable 引擎入口，始终排除游戏资源和玩家数据 |
| 像素黑神话 | `heishenhua/` | Unity IL2CPP 图形、输入和游戏辅助设置 |
| 空洞骑士 | `hk/` | Unity 设置与视频引导/PlayerPrefs 适配 |
| Screen Recorder | `recorder/` | 独立后台采帧控制和停止后视频合成应用 |
| Slay the Spire 2 | `sts2/` | 托管兼容层、PCK 构建与双后端启动 |
| 空洞骑士：丝之歌 | `silksong/` | Unity 6/Rudroid 显示/内存设置、实测效果策略与游戏配置适配 |
| 龙沉异世录 | `sunkendragon/` | 实验性 Unity 移植、玩家资源准备与基线包流程 |
| 泰拉瑞亚 | `terraria/` | 玩家 APK 提取、语言设置和 Unity 启动适配 |
| 吸血鬼幸存者 1.14 | `vampiresurvivors114/` | Unity 6/PAD 游戏的显示、图形兼容与按键适配 |
| Je-Wine | `wine-loongos/` | 机型环境、共享 Wine 组件与独立游戏适配 |
