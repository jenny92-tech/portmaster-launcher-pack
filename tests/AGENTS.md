# 跨模块回归测试

> 验证共享启动器、应用管理界面、资源包与端口声明之间的契约。

## 地位

仓库级主机测试入口，补充 Rust crate 单元测试和个别端口的本地测试。

## 逻辑

Shell 测试读取源码或构造隔离设备/发行夹具，Python 测试用 lupa 模拟 LÖVE 交互；包集成测试还会调用 `_kit/` 组装工具核对生成目录或 ZIP。

## 约束

- 先区分静态检查、临时夹具测试与会改写 dist/ 的打包测试；仅修改文档时不要盲目运行全部打包测试。
- Lua 执行测试依赖 lupa，缺失时会跳过；环境测试设置 PAM_REQUIRE_LUPA=1 时要求依赖存在。
- 构建身份测试依赖与源码匹配的 bundled 二进制，失败时不可仅更新 revision 文本绕过校验。
- 保留用户游戏、设备和真实配置；动态测试应使用临时目录或显式替身。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| APP 环境交互 | `test_appmanager_environment_ui.py` | 模拟环境能力、启动状态、任务与管理页面交互 |
| APP 控制器数据库 | `test_appmanager_controller_database.py` | 验证新增 GUID 的 APP 基础操作覆盖、映射语义与冲突保留 |
| 包构建身份 | `test_build_info.py` | 验证所有端口的标识注入、负载散列与封装身份 |
| APP 原生桥接 | `test_appmanager_inprocess_bridge.sh` | 确保 Lua 只经单一 Rust 请求边界通信 |
| APP 标准 ZIP | `test_appmanager_port_zip.sh` | 检查 PortMaster ZIP 的可重现性、路径和权限 |
| APP 便携包 | `test_appmanager_portable_package.sh` | 检查 runtime、依赖、许可和文件闭集 |
| APP 发布源 | `test_appmanager_sources.sh` | 固定配置中的发布路由与原生消费关系 |
| APP 轻量入口 | `test_appmanager_thin_launcher.sh` | 验证退出码、日志和精确游戏脚本交接 |
| APP runtime 范围 | `test_appmanager_ui_runtime_scope.sh` | 验证 LOVE-lite 产品身份与依赖隔离 |
| Batomon 契约 | `test_batomon_launcher.sh` | 检查 Godot/PCK 入口和专用打包声明 |
| 联系与字体 | `test_launcher_contact.sh` | 检查公共联系信息、共享 UI 引用与中文字体 |
| 字体候选顺序 | `test_love_font_resolution.sh` | 验证公共字体优先及本地回退 |
| LÖVE 发行契约 | `test_love_launcher_contract.sh` | 检查内联模板、共享资源和端口发行集成 |
| Lua 执行契约 | `test_love_lua_modules.py` | 模拟控件、状态、安全参数输出与失败反馈 |
| 公共组件契约 | `test_love_shared_components.sh` | 检查控件接口、端口共享行为与 APP Manager 发行集成 |
| 端口授权 | `test_port_licenses.sh` | 验证授权文本和游戏资源独立声明 |
| 端口截图 | `test_port_screenshots.sh` | 核对 manifest 图片声明和 PNG 文件 |
| PortKit 二进制 | `test_portkit_launcher_tools.sh` | 验证构建身份、架构、大小和分发范围 |
| PortMaster 引导 | `test_portmaster_bootstrap.sh` | 验证探测路径、封面同步和模板展开 |
| 启动平台边界 | `test_launcher_platform.py` | 验证标准 PortMaster API、Wayland/尺寸回退、前端清理与全部普通端口统一入口 |
| 公共音频适配 | `test_portmaster_common_audio.sh` | 以 socket/命令替身验证音频服务定位 |
| SDL 音频路由 | `test_sdl_audio_route.py` | 无设备副作用地验证 ALSA/Pulse 路由与 Loong 隔离 |
| 录屏状态机 | `test_recorder_engine.sh` | 以 ffmpeg 替身验证录制、状态、停止和合成 |
| 龙沉异世录契约 | `test_sunkendragon_launcher.sh` | 检查包配置及玩家资源准备分支 |
| TrimUI APP 归档 | `test_trimui_app_packager.sh` | 验证包装结构、可重现 ZIP 与符号链接防护 |
| Unity 显示参数 | `test_unity_resolution_contract.sh` | 验证显示分辨率与内部渲染比例的配置分离 |
| 吸血鬼幸存者契约 | `test_vampiresurvivors114_launcher.sh` | 检查 Unity 6 图形兼容、插件与存档边界 |
