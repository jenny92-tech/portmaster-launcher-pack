# STS2 掌机移植

ports 下需要独立 C# 构建与着色器打包流程的游戏端口。love 声明设置 UI 和两阶段启动模板；src 实现运行时补丁并提供资源转换、组装和诊断；manifest 将端口接入共享分发工具。

## 约束

- 玩家须自行提供合法游戏内容；遵守游戏和外部运行时的既有分发边界。
- 正式启动的 LÖVE/游戏显示环境保持隔离，设备实验脚本不替代正式入口。
- 当前正式入口在既有 Launchpack 高级页选择匹配的 SDL Godot/GLES 或 PortMaster Godot/Vulkan，自动按设备推荐值解析，手选不可用时拒绝启动；两后端共用玩家档，切换在下次启动生效。统一引擎及 VMA 配置补丁在相邻 `godot-sdl2` 仓库维护；新构建须核验原生/托管接口和设备表现后才能替换现用引擎。外部 WSI、客户端库和显示会话适配与引擎分开维护。
- 当前准入为 MiniLoong 原生 Wayland/Vulkan，以及 TrimUI 的 KMSDRM SDL2/GLES、私有 Weston/Vulkan；以硬件、固件、运行库身份和实际显示前提检测，不以 IP 或单一 SoC 字符串推定其他掌机兼容。SDL2/GLES 可用不代表官方 Godot 原生 Wayland/EGL 已通过。
- 独立 SDL 装配链与正式启动入口分离；正式入口只复用匹配固定身份的已安装 SDL 执行组件，不调用独立安装入口。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| .gitattributes | `.gitattributes` | 二进制和媒体文件的 Git LFS 属性 |
| .gitignore | `.gitignore` | 游戏引用、外部运行时和构建产物忽略规则 |
| LICENSE | `LICENSE` | 本端口许可证文本 |
| README.md | `README.md` | 端口定位、构建流程和外部依赖说明 |
| 开发与资源重建 | `DEVELOPMENT.md` | 输入身份、优化策略、离线构建、运行时安装与升级检查 |
| manifest.json | `manifest.json` | 共享工具消费的端口元数据与启动脚本配置 |
| screenshot.png | `screenshot.png` | 保留原图尺寸与构图的 PortMaster 预览，使用统一圆角细边框与紫猫角底 |
| love | `love/` | 共享 LÖVE 设置声明及 STS2 两阶段启动模板 |
| src | `src/` | 运行时兼容实现、构建输入与移植工具 |
