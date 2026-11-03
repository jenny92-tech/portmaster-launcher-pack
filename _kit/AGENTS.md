# 共享启动、原生工具与包组装

各端口通过 `dist_port.sh` 选择专用构建或共享组装；`assemble.sh` 内联 Shell 模块，再收集 UI、经源码身份校验的原生工具和元数据。封装器消费暂存目录生成 PortMaster/TrimUI 交付，设备端入口独立于仓库运行。

## 约束

- 端口 `dist/` 只作暂存，正式交付归根 `dist/`；布局特殊的端口按自身说明构建，核验后清理重复暂存。打包排除运行状态、缓存与玩家数据。
- 普通端口统一使用 `portmaster_init` 和内联 `launcher_platform.sh`，设备仍需已安装的 PortMaster control、UI runtime 与输入工具。PortMaster 按官方四路径顺序发现，不新增脚本同目录优先或额外 SD 卡猜测。
- `launcher_compat.sh` 为 Godot/SDL2、Unity/Rudroid 先生成补丁计划，失败使旧计划失效。`launcher_compat_exec` 只在已归属的游戏子进程或命令替换中交接原 PID；拥有退出清理的父进程不能被替换。方案匹配不绕过引擎预检、标题声明与验收准入。
- UI 库路径局限于 UI 子进程。`LAUNCHER_UI_RUNTIME_DIR` 可选择已准备的内置 UI 副本，否则沿用 Unity sidecar 的 LÖVE 查找；Rudroid 独占游戏输入和 Select+Start 退出，gptokeyb 只服务设置 UI。
- MiniLoong 保留系统音频与 Wayland 约定；已有效尺寸不重复旋转，仅已知 Loong 的原始 fb 回退交换宽高。硬件策略匹配完整 device-tree compatible，由已验收标题显式选用，固定核心、调频与热插拔不成为公共默认。
- Vulkan 可用性取标题、固件、完整板型、运行库能力及有界原生探测的交集。目前仅登记 Silksong/吸血鬼幸存者的 TrimUI A523 和 Loong RK3566 RK817 路径；未知组合在原生探测前禁用，不凭 IP 或 SoC 子串推定。
- 私有 WSI 暂存到 `runtime/vulkan-wsi`，仅在游戏进程生效，不改系统 ICD/驱动。无系统 Wayland 时，完整私有客户端包和已安装的 PortMaster Weston 均通过检查才可创建临时会话。
- 不可用后端不能选择；已存无效值在显示前归一化，启动校验仍拒绝无效选择，不暗换后端。禁用字段置灰并跳过焦点，滤波由程序处理；图形能力只在启动或选项变化时刷新。
- 标题可显式设置 `RUDROID_WAYLAND_FORCE_RENDERER=1`，让私有 Weston 按输出尺寸合成；不继承任意 Weston 开关，不改客户渲染比例。
- 正式会话仅在非零退出或结构化 ERROR/FATAL 时保存最多 64 KiB 上下文，并按相同条件记录退出内核日志。临时捕获使用事件驱动的有界缓冲，不做定时扫描；显式诊断才保留实时完整输出。
- 原生交付通过对应工程的 Release 身份审计，二进制与 revision 同步真实构建；源码注释和目录文档也可能影响散列。配置与清单版本遵循根目录纪律。
- 录屏逻辑维护在 `recorder.sh`，生成 CLI 通过生成器更新。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 工具说明 | `README.md` | 共享模块、打包与部署约定 |
| 作者角标 | `artwork/` | 游戏与工具共用的紫猫、透明角标图层和圆角遮罩母版 |
| UI 组件 | `love/` | LÖVE 组件、声明式设置与窗口/输入配置 |
| Godot 插件 | `godot/` | 可复制的 Godot 4 运行时性能浮层 |
| 预置工具 | `runtime/` | ARM64 PortKit 和 FFmpeg 构建产物 |
| 兼容产物归档 | `compat/` | 按用途保存小型兼容库、完整来源、ABI、接入说明与静态校验 |
| 模板组装 | `assemble.sh` | 将 KIT 引用内联为自包含启动脚本 |
| UI 暂存 | `stage_love_ui.sh` | 通用/STS2 构建共用的 Lua、LUIS、Fluent 图集、离线二维码及许可收集 |
| 功能图标构建 | `build_ui_icons.cjs` | 将固定来源的 Fluent SVG 离线渲染为物理像素图集和布局 |
| 端口构建 | `dist_port.sh` | 选择构建流程并收集发行内容 |
| ZIP 入口 | `dist_port_zip.sh` | 串联构建与标准 PortMaster 或端口自有 dist-zip.py 封装 |
| TrimUI APP 入口 | `dist_trimui_app.sh` | 串联端口构建与 MainUI APP 封装 |
| PortMaster 元数据 | `port_json.py` | 将内部 manifest 转为发行 port.json |
| 标准 ZIP 封装 | `port_zip.py` | 校验 items、拒绝符号链接并原子生成 ZIP |
| 包构建身份 | `build_info.py` | 对最终负载计算日期与内容散列，生成 build-info.json 并注入启动日志 |
| 迷你龙设备导出 | `package_miniloong.py` | 校验显式导出清单，排除玩家数据和指定标题资源，审计 Release 并生成无密码 7z |
| TrimUI APP 封装 | `trimui_app.py` | 生成系统 APP 入口、图标、配置与 ZIP |
| PortMaster 引导 | `portmaster_bootstrap.sh` | 查找 controlfolder，统一加载标准 control/mod 和手柄配置 |
| 系统适配边界 | `launcher_platform.sh` | 探测真实显示会话、补齐尺寸、处理旧输入/进程名兼容和显式 DRM 所有权请求 |
| 补丁组合计划 | `launcher_compat.sh` | 匹配引擎/固件/完整板型规则，选择私有 WSI 或 SDL，记录计划并仅向游戏子进程应用 |
| 私有执行入口 | `launch_exec_view.py` | 按显式路径准备完整执行视图，以原 PID 交接；正式导出用 --quiet 仅报异常 |
| 通用设备层 | `portmaster_common.sh` | 音频、内存、退出清理及 LÖVE 启动 |
| 私有 Wayland 会话 | `wayland_session.py` | 可选只读 Weston 挂载、独占会话、有界预检与原生退出后清理，保留系统驱动和音频环境 |
| Unity 设备层 | `launcher_unity_common.sh` | 选择可执行运行目录，固定路径写入显示/渲染/内存并运行 Rudroid |
| 封面同步 | `launcher_artwork.sh` | 通过原生辅助程序安全同步前端图片 |
| 录屏引擎 | `recorder.sh` | DRM JPEG 抓帧、会话状态与离线 MP4 合成 |
| 录屏 CLI 生成 | `build_recorder_tool.sh` | 从共享引擎生成 tools/record_screen.sh |
| FFmpeg 构建 | `build_ffmpeg_recorder.sh` | 构建静态 ARM64 最小录屏运行时 |
| LOVE-lite 构建 | `build_appmanager_love_lite.sh` | 调度容器、安装二进制并记录源码身份 |
| LOVE-lite 容器构建 | `build_appmanager_love_lite_in_container.sh` | 编译并暂存 SDL 后端运行时 |
| PortKit 构建 | `build_portkit_launcher.sh` | 构建静态 ARM64 启动辅助程序 |
| PortKit 暂存 | `stage_portkit_launcher.sh` | 拒绝过期或错误架构的预置辅助程序 |
| Cargo 闭包散列 | `cargo_revision.py` | 散列输入路径、锁文件依赖闭包与 TOML 部分 |
| LOVE-lite 身份 | `love_lite_revision.py` | 计算管理运行时的源码 revision |
| PortKit 身份 | `portkit_launcher_revision.py` | 计算游戏辅助程序的源码 revision |
| PortKit 构建记录 | `portkit-launcher-revision.txt` | 对应预置二进制的构建输入身份 |
