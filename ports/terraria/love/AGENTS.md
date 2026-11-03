# 泰拉瑞亚启动界面

模板检测 APK 后交给 patcher，Lua 再按核心资源就绪状态提供设置并输出 TER_* 参数。游戏语言通过 PortKit 合并 conf/config.json，显示/内存/输入通过 Unity 配置更新；所有核心路径均以 gamedata 为基准。

## 约束

- 本标题固定 GLES，新状态默认 75% 渲染，隐藏不可配置的后端和滤波选项；不适用的可调项显示“禁用”并跳过焦点，输出安全值。
- 渲染分辨率在常用页；输出显示尺寸、A/B 与 X/Y 交换放高级页。常用页三档内存写 Rudroid runtime.memory_mode，默认均衡。
- 核心资源路径必须相对 gamedata/，与 config.toml 和 patch/ 一致。
- 语言默认值为 7；通过 PortKit JSON 合并 Language 字段，保留配置中的其他内容，不使用 sed/awk 替换。
- UI 显示环境不泄漏到游戏；Start 按键和软键盘确认行为按游戏输入契约保留。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 选项与门禁 | `main.lua` | 语言与 TER_* 字段、APK/核心资源门禁 |
| 启动模板 | `launcher.sh.template` | 调用 patcher、结构化配置更新与 Unity 启动 |
