# 共享启动与打包工具

> 将端口源码、公共设备逻辑和运行时输入组装为可分发的掌机启动包。

## 地位

各 `ports/` 的公共构建入口和运行时 Shell/Lua 基础设施，原生复杂能力由 `crates/` 实现。

## 逻辑

`dist_port.sh` 选择端口专用脚本或共享组装流程；`assemble.sh` 内联模板中的 KIT 模块，随后收集 UI、运行时和元数据。ZIP/TrimUI 封装消费 dist；预置二进制通过独立源码 revision 校验后暂存。

## 约束

- 仅生成的 `ports/<port>/dist/` 用于部署；设备不得依赖仓库 `_kit/` 目录。
- 平台能力与 Unity 专用逻辑分离：普通端口统一使用 `portmaster_init` 和随包内联的 `launcher_platform.sh`，不依赖定制 PortMaster；仍需已安装的 PortMaster control、UI runtime 与输入工具。
- PortMaster 路径严格按官方模板的四项顺序查找，不添加启动脚本同目录优先或额外 SD 卡路径。
- MiniLoong 的系统音频/Wayland 环境保持既有约定；已有效的显示尺寸不做二次旋转，只有已知 Loong 的原始 fb 尺寸回退才交换宽高。
- 原生运行时与 revision 必须由对应构建流程同步生成；注释与文档变化也可能使内容散列失效。
- 配置/清单版本保持当前值；打包不得包含运行状态、缓存或用户游戏数据。
- 录屏脚本维护 `_kit/recorder.sh`，生成的 CLI 不手工修改。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 工具说明 | `README.md` | 共享模块、打包与部署约定 |
| UI 组件 | `love/` | LÖVE 组件、声明式设置与窗口/输入配置 |
| 预置工具 | `runtime/` | ARM64 PortKit 和 FFmpeg 构建产物 |
| 模板组装 | `assemble.sh` | 将 KIT 引用内联为自包含启动脚本 |
| 端口构建 | `dist_port.sh` | 选择构建流程并收集发行内容 |
| 标准 ZIP 入口 | `dist_port_zip.sh` | 串联端口构建与 PortMaster ZIP 封装 |
| TrimUI APP 入口 | `dist_trimui_app.sh` | 串联端口构建与 MainUI APP 封装 |
| PortMaster 元数据 | `port_json.py` | 将内部 manifest 转为发行 port.json |
| 标准 ZIP 封装 | `port_zip.py` | 校验 items、拒绝符号链接并原子生成 ZIP |
| TrimUI APP 封装 | `trimui_app.py` | 生成系统 APP 入口、图标、配置与 ZIP |
| PortMaster 引导 | `portmaster_bootstrap.sh` | 查找 controlfolder，统一加载标准 control/mod 和手柄配置 |
| 系统适配边界 | `launcher_platform.sh` | 探测真实显示会话、补齐尺寸、处理旧输入/进程名兼容和显式 DRM 所有权请求 |
| 通用设备层 | `portmaster_common.sh` | 音频、内存、退出清理及 LÖVE 启动 |
| Unity 设备层 | `launcher_unity_common.sh` | 统一原子写入显示/渲染比例，应用按键设置并运行 unityloader |
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
