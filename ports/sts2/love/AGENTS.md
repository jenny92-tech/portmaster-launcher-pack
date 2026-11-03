# STS2 启动器界面

本移植的 LÖVE 前端与 PortMaster 启动模板入口。main.lua 使用共享 launcher 定义字段；图形后端由 Shell 提供设备能力并由启动器解析。

## 约束

- 共享界面通过 _kit 组装，不在本目录复制共享逻辑。
- 常用页保留语言和画质预设；图形后端、A/B 与 X/Y 交换、显示合成、性能信息和诊断日志开关放高级页。
- 首次打开时 `SLL_INITIAL_LANGUAGE` 仅接受 `zh_CN`、`en_US`，`SLL_INITIAL_QUALITY` 仅接受 `smooth`、`balanced`、`quality`；无效或缺失时使用原默认，有已保存设置时以已保存值为准。
- Shell 以 `SLL_GLES_AVAILABLE=1`、`SLL_VULKAN_AVAILABLE=1` 标明可用能力，并可用 `SLL_GRAPHICS_PREFERRED` 指定 `gles` 或 `vulkan`。默认 `auto` 优先选可用的推荐后端，否则优先 GLES，再选 Vulkan；保存 `auto` 而向 Shell 输出实际后端。手选不可用后端保留偏好但禁止启动。
- 强制合成只提供开/关，默认开；仅在实际解析为 Vulkan 且 Shell 提供 `SLL_WESTON_COMPOSITION_AVAILABLE=1` 时可调，不支持时灰显并输出 `off`，保留已保存的开关偏好。字段仅接受 `on`、`off`，其他值按共享校验采用默认 `on`；图形后端的自动选项与此独立。
- A/B、X/Y 交换目前禁用并输出 off，保存的偏好不删除；仅在按设备核实完整控制器映射并验证按键与重连后才能启用。
- LÖVE 与游戏的显示环境分离；游戏阶段不使用 gptokeyb 抓取输入，也不传 --verbose。
- 玩家已有存档只同步明确指定的设置；游戏文件由玩家提供。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| main.lua | `main.lua` | STS2 的图形后端、语言、画质与高级设置声明 |
| 界面契约测试 | `test_main.py` | 离线验证后端可用性、已存设置与启动环境交接 |
| launcher.sh.template | `launcher.sh.template` | 按设备能力交接游戏图形后端并拒绝不可用配置 |
| Vulkan 手动测试 | `vulkan-trial.sh.template` | 官方 Godot4.5 Mono 的迷你龙 Vulkan 入口，校验游戏侧性能补丁及可选独立纹理包，保留独立存档及正式入口 |
| TrimUI 新版独立入口 | `trimui-v110.sh.template` | 已有 SDL Godot 与私有 KMSDRM 库的独立 0.110.1 入口，不覆盖旧存档 |
