# STS2 启动器界面

`main.lua` 使用共享 launcher 将已保存设置和 Shell 提供的能力解析为实际游戏参数，模板据此交接后端。`launcher.sh.template` 是正式入口；其余两个模板分别供隔离 Vulkan 检查和 TrimUI 0.110.1 独立运行使用，资源和档案位置按各自模板校验，不能把独立入口当作正式后端路由。

## 约束

- 常用页保留语言和画质预设；图形后端、A/B 与 X/Y 交换、显示合成、性能信息和诊断日志开关放高级页。
- 首次打开时 `SLL_INITIAL_LANGUAGE` 仅接受 `zh_CN`、`en_US`，`SLL_INITIAL_QUALITY` 仅接受 `smooth`、`balanced`、`quality`；无效或缺失时使用原默认，有已保存设置时以已保存值为准。
- Shell 以 `SLL_GLES_AVAILABLE=1`、`SLL_VULKAN_AVAILABLE=1` 标明可用能力，并可用 `SLL_GRAPHICS_PREFERRED` 指定 `gles` 或 `vulkan`。默认 `auto` 优先选可用的推荐后端，否则优先 GLES，再选 Vulkan；保存 `auto` 而向 Shell 输出实际后端。手选不可用后端保留偏好但禁止启动。
- 强制合成只提供开/关，默认开；仅在实际解析为 Vulkan 且 Shell 提供 `SLL_WESTON_COMPOSITION_AVAILABLE=1` 时可调，不支持时灰显并输出 `off`，保留已保存的开关偏好。字段仅接受 `on`、`off`，其他值按共享校验采用默认 `on`；图形后端的自动选项与此独立。
- A/B、X/Y 交换目前禁用并输出 off，保存的偏好不删除；仅在按设备核实完整控制器映射并验证按键与重连后才能启用。
- LÖVE 与游戏的显示环境分离；游戏阶段不使用 gptokeyb 抓取输入，也不传 --verbose。
- 两阶段启动只同步明确指定的游戏设置，不改玩家其他档案；后端切换在下次启动生效。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| main.lua | `main.lua` | 能力交集、语言/画质初值与启动环境输出 |
| 界面契约测试 | `test_main.py` | 已存偏好、后端不可用拒绝和环境交接契约 |
| launcher.sh.template | `launcher.sh.template` | 正式 GLES/Vulkan 路由与启动校验 |
| Vulkan 手动测试 | `vulkan-trial.sh.template` | 隔离档案的 Mono Vulkan 与纹理包试验 |
| TrimUI 新版独立入口 | `trimui-v110.sh.template` | 固定 SDL Godot/KMSDRM 的 0.110.1 独立入口 |
