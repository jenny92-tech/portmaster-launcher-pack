# 跨模块回归测试

仓库级主机测试入口，补充 Rust crate 单元测试和个别端口的本地测试。Shell 测试读取源码或构造隔离设备/发行夹具，Python 测试用 lupa 模拟 LÖVE 交互；包集成测试还会调用 `_kit/` 组装工具核对生成目录或 ZIP。

## 验证约定

- 按改动范围选择静态检查、隔离夹具或组包集成测试；组包测试会生成 dist。运行时身份检查使用与源码匹配的二进制。
- Lua 交互测试依赖 Lupa；`PAM_REQUIRE_LUPA=1` 将其设为必需依赖。动态检查使用隔离临时目录和命令替身。
- STS2 可选集成输入通过显式变量提供，缺失依赖时注明跳过原因；合成回归独立执行。宿主 Godot 用 `STS2_TEST_GODOT`，ARM64 引擎用 `STS2_TEST_GODOT_ARM64`，RichTextLabel 变体用 `STS2_TEST_GODOT_RICHTEXT_ARM64`。
- 字体集成使用 `STS2_TEST_SOURCE_PCK`；三字体增量/报告用 `STS2_TEST_FONT_CACHE_DELTA`、`STS2_TEST_FONT_CACHE_REPORT`，六字体用 `STS2_TEST_COMMON_FONT_CACHE_DELTA`、`STS2_TEST_COMMON_FONT_CACHE_REPORT`。输入匹配工具要求的身份。
- Windows 资源准备使用 `STS2_TEST_WINDOWS_GAME_DIR`，完整集成另需 `STS2_TEST_LINUX_BASELINE_DIR`，默认只运行合成回归。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| PCK 显式补丁输入 | `test_sts2_pck_blob_patch.py` | 用合成数据验证原内容与替换内容拒绝、等长替换、幂等及无默认资源快照 |
| STS2 正式入口 | `test_sts2_official_launcher.py` | 设备与渲染门禁、前端显示交接、WSI 搜索和有界日志的主机回归 |
| STS2 SDL 入口 | `test_sts2_trimui_v110.py` | 独立 SDL 启动模板及默认关闭诊断的契约 |
| SFX 解包边界 | `test_sts2_windows_sfx_archive.py` | 输入拒绝、资源清单及显式 STS2_SFX_SOURCE/STS2_SFX_UNRAR 夹具的沙箱回归 |
| STS2 TrimUI 合成设置 | `test_sts2_trimui_composition.py` | 验证开启、关闭、缺省和非法值对私有 Weston 环境的影响 |
| STS2 TrimUI 渲染能力 | `test_sts2_graphics_capabilities.py` | 验证 GLES/Vulkan 依赖独立检测和 SDL 子进程环境隔离 |
| APP 环境交互 | `test_appmanager_environment_ui.py` | 管理界面布局、导航、任务状态、配对及错误恢复 |
| APP 控制器数据库 | `test_appmanager_controller_database.py` | 验证新增 GUID 的 APP 基础操作覆盖、映射语义与冲突保留 |
| 包构建身份 | `test_build_info.py` | 验证所有端口的标识注入、负载散列与封装身份 |
| APP 原生桥接 | `test_appmanager_inprocess_bridge.sh` | 确保 Lua 只经单一 Rust 请求边界通信 |
| APP 标准 ZIP | `test_appmanager_port_zip.sh` | 检查 PortMaster ZIP 的可重现性、路径和权限 |
| APP 便携包 | `test_appmanager_portable_package.sh` | 检查 runtime、依赖、Fluent 图集/布局/许可的完整分发和文件闭集 |
| APP 发布源 | `test_appmanager_sources.sh` | 固定配置中的发布路由与原生消费关系 |
| APP 轻量入口 | `test_appmanager_thin_launcher.sh` | 验证退出码、日志和精确游戏脚本交接 |
| APP runtime 范围 | `test_appmanager_ui_runtime_scope.sh` | 验证 LOVE-lite 产品身份与依赖隔离 |
| Batomon 契约 | `test_batomon_launcher.sh` | 检查 Godot/PCK 入口和专用打包声明 |
| STS2 字体图集候选 | `test_sts2_font_atlas_trial.py` | 校验字体参数、共享回退、闭集和语言语料抽取 |
| STS2 外部测试输入 | `sts2_test_inputs.py` | 仅解析显式文件/目录变量并给出缺失原因，不猜测本地缓存 |
| STS2 字体缓存重载 | `test_sts2_font_cache.py`、`test_sts2_common_font_cache.py` | 保留合成身份拒绝；显式私有输入可选验证三/六字体的 Linux ARM64 重载 |
| STS2 地图画布候选 | `test_sts2_map_canvas_trial.py` | 校验画布输入身份、物理/逻辑尺寸分离、单项合并与无关资源保持 |
| STS2 Mono 字体子集 | `test_sts2_subset_mono_font.py` | 检查CJK字宽、变体序列与非CJK保留规则 |
| STS2 字体预算合并 | `test_sts2_merge_font_budget.py` | 验证四项闭集、报告拒绝与其他资源不变 |
| STS2 字体预算 | `test_sts2_font_budget_trial.py` | 检查固定粗体资源身份、共享字库变更及拒绝非预期输入 |
| 联系与字体 | `test_launcher_contact.sh` | 检查公共联系信息、共享 UI 引用与中文字体 |
| 字体候选顺序 | `test_love_font_resolution.sh` | 验证公共字体优先及本地回退 |
| LÖVE 发行契约 | `test_love_launcher_contract.sh` | 检查内联模板、共享资源和端口发行集成 |
| APP 自适应布局 | `test_app_adaptive_layout.py` | Lua 5.1/5.4 多尺寸功能导航、完整工具按钮/动态数量、列表滚动、统一确认方位/单按钮结果、按键校正前后固定操作提示、可达勾选、下拉筛选、子页返回与二维码静区/缓存 |
| LUIS 接入 | `test_luis_components.py` | Lua 5.1/5.4 真实控件绘制/回调、像素边界、空闲与依赖分发 |
| Lua 执行契约 | `test_love_lua_modules.py` | 模拟控件、状态、安全参数输出与失败反馈 |
| 公共组件契约 | `test_love_shared_components.sh` | 检查控件接口、端口共享行为与 APP Manager 发行集成 |
| 端口授权 | `test_port_licenses.sh` | 验证授权文本和游戏资源独立声明 |
| 端口截图 | `test_port_screenshots.sh` | 核对 manifest 图片声明和 PNG 文件 |
| PortKit 二进制 | `test_portkit_launcher_tools.sh` | 验证构建身份、架构、大小和分发范围 |
| PortMaster 引导 | `test_portmaster_bootstrap.sh` | 验证探测路径、封面同步和模板展开 |
| 启动平台边界 | `test_launcher_platform.py` | 验证 PortMaster API、显示回退、UI 失败门禁、私有库和全部普通端口统一入口 |
| 补丁组合计划 | `test_launcher_compat.py` | 验证精确准入、失败失效、WSI/SDL 私有环境、音频路由保留、字面参数、PID/退出码与八入口内联 |
| 兼容产物归档 | `test_compat_archive.py` | 验证 WSI 实体校验值、ABI 记录、损坏/错架构/LFS 指针及路径和文件闭集 |
| STS2 焦点兼容 | `test_sts2_input_focus.py` | 合成程序集验证焦点开关、平台覆盖层和未知输入拒绝 |
| STS2 资源诊断 | `test_sts2_asset_diagnostics.py` | 合成会话验证诊断开关、完成幂等、路径上限及原 Task/缓存保留 |
| STS2 输入诊断 | `test_sts2_input_diagnostics.py` | 合成 Godot API 检查诊断默认关闭、有界汇总和输入类别计数 |
| STS2 诊断隔离 | `test_sts2_diagnostic_xdg.py`、`test_sts2_runtime_counters.py` | 临时用户目录和缓存链接防别名、聚合计数工具与转发清理，不操作设备 |
| STS2 VRAM 恢复 | `test_sts2_restore_vram_texture.py`、`sts2_restore_vram_fixture.gd` | 合成纹理测试 shader 数据保护、ASTC采样质量和图集逻辑坐标 |
| STS2 四分之一纹理 | `test_sts2_quarter_texture.py`、`sts2_quarter_texture_fixture.gd`、`sts2_quarter_texture_reload.gd` | 合成纹理验证保护规则、ASTC8质量门与图集逻辑坐标，并可离线重载私有候选 |
| STS2 四分之一纹理精修 | `test_sts2_refine_quarter_texture.py` | 验证尺寸收益、质量门、源身份拒绝和隔离解码 |
| STS2 隔离 UI 观察 | `test_sts2_ui_diagnostic.py`、`sts2_ui_diagnostic_fixture.gd`、`sts2_ui_diag_gate_fixture.gd`、`sts2_ui_diag_linux_integration.gd` | 无头假控件及本机可选Linux容器验证双开关、隔离目录、符号链接门、原生getter对抗与文本边界 |
| STS2 纹理诊断 | `test_sts2_texture_diagnostic.py`、`sts2_texture_diagnostic_fixture.gd`、`sts2_texture_cache_fixture.gd`、`sts2_texture_diagnostic_mount_fixture.gd` | 合成 Godot 场景验证共享纹理去重、缓存查询无加载及不持有、viewport 参数与诊断包只读挂载 |
| STS2 资源内存候选 | `test_sts2_memory_candidates.py` | 合成 PCK 验证依赖去重、身份门和纹理物理尺寸估算 |
| STS2 Windows 启动资源 | `test_sts2_windows_runtime_resources.py` | 合成项目二进制和扩展配置验证 Sentry 自加载移除、ARM64 映射及非目标字段保留 |
| STS2 官方运行时资源补丁 | `test_sts2_official_runtime_patch.py` | 验证菜单及显式流畅档轻量场景覆盖的修改边界、精确资源闭集和未知或缺失输入拒绝；玩家场景仅可选读取本机缓存，不启动游戏 |
| STS2 shader 类型扫描 | `test_shader_features.py` | 合成 PCK 验证材质、shader 分类、依赖闭包和私有输出保护 |
| STS2 VFX 静态扫描 | `test_vfx_catalog.py` | 合成 PCK 检查循环依赖、实例覆盖、粒子材质、shader、确定性与输入保护 |
| STS2 轻量特效 | `test_sts2_lean_effects.py`、`sts2_lean_effects_fixture.gd` | 合成场景校验精确身份、轻量资源闭集与短动画自动释放，无需玩家游戏或设备 |
| Godot 性能浮层 | `test_godot_performance_overlay.py`、`godot_performance_overlay_fixture.gd` | 无头验证浮层生命周期、暂停采样、宿主输入、布局与指标回退 |
| STS2 轻量特效 | `test_sts2_lean_effects.py`、`sts2_lean_effects_fixture.gd` | 验证轻量场景身份、闪光清理及治疗计时根生命周期 |
| STS2 低内存 | `test_sts2_lean_memory.py` | 独立 .NET/Cecil 夹具验证显式低内存图集按需加载及清理后重载 |
| STS2 低清纹理接入 | `test_sts2_texture_overlay_integration.py`、`test_sts2_texture_merge.py` | 合成资源测试流式合并、Godot 加载、身份绑定及启动拒绝，不访问设备或玩家游戏 |
| STS2 纹理传输 | `test_sts2_texture_upload.py` | 离线模拟上传和下载续传、损坏及来源变化拒绝和设备路径保护，不连接设备 |
| STS2 资源清理 | `test_sts2_texture_cleanup.py` | 模拟清理预检、清单、进程引用和目录链接保护，不连接设备 |
| STS2 手持构建入口 | `test_sts2_optimize_handheld.py` | 验证本机计划、显式/PATH 工具选择、输入引用和未知身份拒绝，不连接设备 |
| STS2 Windows 输入准备 | `test_sts2_prepare_windows_game.py` | 合成 PE/依赖图验证架构与身份门禁；可选原始输入仅经显式变量开启，源文件只读、准备输出在临时目录 |
| STS2 特效 IL 审计 | `test_sts2_vfx_material_audit.py` | 验证静态扫描识别湍流访问及干净程序集 |
| STS2 启动预载 | `test_sts2_startup_preload.py`、`sts2_startup_preload_fixture.gd` | 隔离验证资源加载、终态、超时及退出清理，不实例化游戏根节点 |
| STS2 原生渲染 | `test_sts2_render_native.py`、`sts2_render_native_fixture.gd` | Godot 无头合成场景验证渲染策略、精确粒子规则在父节点准备前生效及资源隔离、材质、缓存与房间生命周期 |
| STS2 低内存 | `test_sts2_lean_memory.py` | 用隔离托管替身验证显式模式、核心图集预取和图集查询按需加载 |
| STS2 渲染桥 | `test_sts2_render_bridge.py` | .NET 替身验证反射桥、资源所有权和战斗预热边界 |
| STS2 原生事件与计时 | `test_sts2_native_particles.py` | 可选 .NET 夹具验证粒子策略、帧停顿/管线记录与诊断失败隔离，不执行游戏 |
| 异常日志 | `test_launcher_logging.py` | 正常退出静默、非零状态与可恢复错误保留、显式诊断、早退及条件内核日志 |
| 开发执行视图 | `test_launch_exec_view.py` | 验证整卡/嵌套运行时覆盖、权限失败门禁和 PID/信号交接 |
| 公共音频适配 | `test_portmaster_common_audio.sh` | 以 socket/命令替身验证音频服务定位 |
| SDL 音频路由 | `test_sdl_audio_route.py` | 无设备副作用地验证 ALSA/Pulse 路由与 Loong 隔离 |
| 录屏状态机 | `test_recorder_engine.sh` | 以 ffmpeg 替身验证录制、状态、停止和合成 |
| 龙沉异世录契约 | `test_sunkendragon_launcher.sh` | 检查包配置及玩家资源准备分支 |
| TrimUI APP 归档 | `test_trimui_app_packager.sh` | 验证包装结构、可重现 ZIP 与符号链接防护 |
| 私有 Wayland 生命周期 | `test_wayland_session.py` | 音频环境隔离、退出码、合成器故障和挂载清理的无设备回归 |
| Unity 显示参数 | `test_unity_resolution_contract.sh` | 验证显示/渲染分离、三档内存、绝对配置路径和失败传播 |
| Unity 设置集成 | `test_unity_launcher_settings.py` | 用隔离夹具和真实主机辅助程序验证五标题配置、精确机型准入、未知设备探测前拒绝、交接失败与原生退出所有权，不启动游戏 |
| 吸血鬼幸存者契约 | `test_vampiresurvivors114_launcher.sh` | 检查 Unity 6 图形兼容、插件与存档边界 |
| Wine 启动器 | `test_wine_loongos_launcher.py` | 验证游戏发现、封面解码/回退、说明弹层、横向导航、输入复用与独占、全屏交接、逐启动帧信号、独立会话及正常退出 |
| Wine 分层与安装 | `test_wine_loongos_layers.py` | 验证机型/环境继承、不依赖系统 Python/PortMaster、API 共享依赖、原子安装保留存档、版本和资源补丁及独立包边界 |
| Wine 离线运行包 | `test_wine_loongos_packages.py` | 验证标准 ZIP 清单、改名及卡根目录发现、内置目录校验、恶意路径拒绝、缓存复用及挂载前安装门禁 |
| Wine Windows 布局 | `test_wine_loongos_layout.py` | 验证 bottle 读入、库/状态分离、SD 卡独立包与真实 Ports 桥接，不连接设备或执行游戏 |
