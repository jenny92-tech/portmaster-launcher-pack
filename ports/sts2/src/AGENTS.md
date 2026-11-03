# STS2 兼容源码与构建输入

正式构建器从 STS2LinuxLauncher、rendering、shaders 收集兼容代码和资源，再与 external/runtime 指定的引擎组件装配。离线转换和设备诊断由 tools 提供独立接口；linux 目录只给出玩家数据准备与运行配置，不是游戏资源来源。

## 约束

- 游戏原版程序集和资源由玩家提供，不在源码树或发布包中分发。
- external 记录外部运行时来源、固定补丁和构建方式；runtime 保存随包二进制及版本记录。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| STS2LinuxLauncher | `STS2LinuxLauncher/` | ModEntry 与 Harmony 资源/平台补丁 |
| external | `external/` | Godot/FMOD/Spine 来源及固定补丁说明 |
| linux | `linux/` | 玩家游戏数据准备说明与 .NET 运行时配置模板 |
| runtime | `runtime/` | 随端口提供的 KMSDRM SDL2 二进制和版本记录 |
| scripts | `scripts/` | 兼容层构建、覆盖包、运行时装配和部署 |
| shaders | `shaders/` | Mali 友好的 Godot 替代着色器 |
| 独立纹理诊断 | `texture_diagnostics/` | 仅供显式挂载的小包，分帧采集可达纹理及 viewport 元数据 |
| 游戏侧渲染准备 | `rendering/` | Godot 节点侧材质、预热与缓存策略 |
| tools | `tools/` | 独立输入验证、程序集/PCK 转换和诊断 |
