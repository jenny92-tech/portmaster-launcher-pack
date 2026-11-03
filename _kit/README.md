# 共享启动与打包工具

`ports/<name>/love/` 维护设置声明和 Shell 模板；`dist_port.sh` 组装成自包含设备入口。
只部署生成的 `ports/<name>/dist/`，设备不需要仓库 `_kit/`。

该目录是组包暂存，核验后将最终包收进根 `dist/`，未压缩交付目录归
`dist/ports/<port>/`；同内容的暂存和成品只留一份。目录、缓存预算及收尾规则见
[根 AGENTS](../AGENTS.md#工作目录与产物生命周期)。

| 操作 | 入口 |
|---|---|
| 组装端口 | `_kit/dist_port.sh PORT` |
| 生成 PortMaster ZIP | `_kit/dist_port_zip.sh PORT` |
| 生成 TrimUI APP ZIP | `_kit/dist_trimui_app.sh PORT [OUTPUT]` |
| 重建游戏辅助程序 | `_kit/build_portkit_launcher.sh` |
| 录屏 CLI | `_kit/build_recorder_tool.sh`，源文件是 `recorder.sh` |
| App Manager 私有 UI runtime | `_kit/build_appmanager_love_lite.sh`，普通游戏不用此 runtime |

模块导航和构建约束见 [AGENTS](AGENTS.md)；UI API 见 [love](love/README.md)。
PortKit 预置二进制必须匹配源码 revision，由构建生成，不能只修改 revision 文本。

## 自动补丁组合

`launcher_compat.sh` 是随入口内联的后台适配模块，不增加玩家页面、运行时 Python
依赖或 SSH 命令拼接。现有六个 Unity 入口与 STS2、Batomon 使用同一套计划接口：

```sh
launcher_compat_plan STACK BACKEND RUNTIME_DIR [BUNDLED_SDL_DIR]
launcher_compat_describe
( launcher_compat_exec EXECUTABLE ARGUMENTS... )
```

调用方先加载 `launcher_platform.sh`。计划只读取设备/运行库信息并写入自己的
`LAUNCHER_COMPAT_*` 输出；选择失败立即使旧计划失效。`describe` 只打印所选方案、
补丁及私有库路径，不读取整份环境。`exec` 必须放在原游戏子进程、后台任务或一次性
预检命令替换里，应用环境后通过平台 hook 交接进程，保留 PID、参数和退出码。
父启动器继续拥有 UI 和退出清理，不会收到游戏的私有 SDL/WSI 环境。

| 技术栈与后端 | 已接入的组合 |
|---|---|
| `unity-rudroid / gles` | 现有系统 GLES，不增加图形补丁 |
| `unity-rudroid / vulkan` | 已登记的游戏/固件/完整板型组合，要求私有 WSI 文件齐全 |
| `godot-sdl2 / gles` | 真实 Wayland 优先；保留固件 SDL 驱动；必要时选择声明的私有 KMSDRM SDL |

Unity 保留原有运行库特性查询和有界原生 Vulkan 预检，匹配规则不等于验收通过。
Godot SDL 的库字符串检测只沿用现有驱动选择提示，不作为真实 GPU 能力证明；
缺少可用驱动时提前说明原因，不以 dummy 启动需要 GL 的引擎。音频模块后来选定的
Pulse/ALSA 路由优先于兼容层默认值。此模块不把 Godot 原生 Wayland、SDL2 Godot、
Unity 和 Wine 的运行时混用，也不自动给其他技术栈加逐绘图调用的 `glFinish`。
Wine 继续使用自身的机型/环境/组件分层与独立安装器。

新增适配先在公共规则中限定真实硬件/固件和技术栈，再补运行库检查及实机验收。
同一库可复用时共用构建身份，有 ABI/补丁差异时独立记录。共享兼容产物中的一份
344KiB 的 Wayland Vulkan WSI 归档到 [compat](compat/README.md)，说明其目的、
层级、上下游、实际 ABI、来源、接入与重编条件，并配置 Git LFS。定制完整 Godot
仍不入库；其他产物待测试确定。稳定可下载的产物记录固定地址、版本与 SHA256，
难获取或自行修改的产物携带来源、许可和构建记录；每个游戏包只收集所需产物。

## Unity 配置契约

六个 Unity 启动器共用 `launcher_unity_common.sh`：

```sh
configure_unity_display FILE WIDTH HEIGHT RENDER [MEMORY_MODE] [GRAPHICS_API]
run_unity_game "$PORT_TOML" "$GAMEDIR/gamedata/lib:$GAMEDIR/gamedata/lib/arm64-v8a"
```

| 设置 | 写入位置 |
|---|---|
| 高级：输出尺寸 | `[device].displayWidth/displayHeight`，Auto 跟随设备 |
| 常用：渲染尺寸 | `[gpu].renderScalePercent/renderWidth/renderHeight` |
| 常用：低/均衡/高内存 | `[runtime].memory_mode`，五个正式 Rudroid 端口 |
| 高级：A/B、X/Y | `[input.remap]` |
| 游戏效果/辅助项 | 各标题自己的补丁表 |

Game preset 保留精确尺寸（例如 960×720 输出、640×480 渲染）；显式比例 100/75/50
清除旧精确对，保留滤镜。内存档影响受支持的资源流/音频默认策略，不自动联动帧率、
画质或渲染线程；它也不是电脑端资源转换器的 1/2/4 GiB 压缩档。
实验性 sunkendragon 不显示 Rudroid 内存档。实验性批量资源卸载固定关闭，不设菜单。

TOML 经 PortKit 类型化原子合并，仅改拥有的键；null 删除键，解析/保存失败停止启动。
`PORT_TOML` 固定到绝对 `GAMEDIR`；UI 状态和 env 属于实际 UI 目录。
不能截断表、写错根表或从别的目录加载同名配置。UI 未运行成功时不读取旧 env。

## 运行目录与部署

五个正式端口使用整套 Rudroid，保留 `unityloader` 启动别名，能力目录为
`rudroid.runtime/`；完整 kit 的生成/审计遵守独立 Rudroid 工程的 `BUILD-DOCKER.md`，
需另外准备该源码工程。
noexec 介质可使用已安装的 `/userdata/<port>-runtime` 或显式绝对
`UNITY_RUNTIME_DIR`。这里只放 loader、能力和必要辅助程序；资源、TOML、UI 状态、
存档仍使用原游戏/UI 根。UI 子进程的私有库路径不能泄漏到游戏。

生成的 SH、`love_ui/` 和匹配的 `bin/portkit-launcher` 一起更新，保留设备
`state.txt`、`launch_config.env`、游戏配置、存档与玩家资源。Sunken Dragon
是独立未完成实验，不能用五标题验收代替它的逻辑验证。

## 平台与包边界

普通端口经 `portmaster_init` 使用系统/固件提供的 PortMaster control、UI 和输入工具。
显示适配基于真实会话；Wayland/X11/KMS/音频和 DRM 所有权处理集中在
`launcher_platform.sh`/`portmaster_common.sh`，不在每个游戏复制设备分支。
已有旋转不重复做；独占 DRM 请求在合成器环境不抢占，退出恢复已暂停前端。

`assemble.sh` 内联 `#@KIT`；`dist_port.sh` 收集公共 UI、端口覆盖、runtime 和元数据。
字体首次运行从 PortMaster 准备。App Manager 使用独立的私有 Rust/LOVE-lite 进程。
封面仅同步同名包资源且不覆盖现有文件；普通启动器打包不包含缓存、日志、备份、存档或游戏数据。

`package_miniloong.py` 从显式提供的设备快照及逐文件 SHA256 清单生成 `ports/<port>/dist/` 和无密码 7z，不连接或启动设备。此入口用于个人安装迁移；游戏内容的分发边界由其自身许可决定。泰拉瑞亚和植物大战僵尸始终排除游戏资源，所有标题排除玩家档案和运行状态。Rudroid loader 与插件通过指定的 `kit_markers.py` 逐项审计，启动入口使用私有执行视图并仅报告异常。

```sh
python3 _kit/package_miniloong.py --prepared /path/to/device-export \
  --port terraria --output /path/to/archives \
  --rudroid-scripts ../rudroid/crates/scripts
```

PortKit 的 GitHub 路由按 release/raw/archive/clone/api 等能力选择并校验内容后发布，
APP 通过进程内共享库使用；普通启动器只携带声明所需的静态 helper。
最终负载由 `build_info.py` 计算内容散列和 UTC 日期；这是构建身份，不升级配置/API 版本。
发行经过 dist 入口，单独 assemble 的脚本没有完整包身份。

## 设备开发测试入口

正式启动继续走固件首页。ADB/Python 直接运行游戏脚本时，使用
`launch_exec_view.py` 准备整条执行链所在的挂载视图，覆盖同卡的 LÖVE、输入工具、
PortKit、引擎及原生库。已有执行权限时直接交接；需要时创建私有 mount namespace，
关闭挂载传播，再仅清除指定路径所在挂载点及其嵌套运行时挂载的 `noexec`。
读写、nosuid/nodev 等其他标志保持不变，原有运行时子挂载保留。

例如 MiniLoong 上经已连接 ADB 流式执行，无需安装 Python 包：

```sh
adb -s DEVICE_SERIAL shell python3 - --root /roms/ports -- \
  /bin/bash /roms/ports/Je-吸血鬼幸存者_114.sh < _kit/launch_exec_view.py
```

设备需要系统 Python 3；仅在处理 `noexec` 时需要 mount namespace 和相应挂载权限。
依赖位于另一挂载时，重复 `--root` 指定实际工具目录。权限不足会在启动游戏前明确停止，
应改用固件正常入口。工具不复制运行文件、不修改父进程/固件的挂载，也不常驻监督；
原命令保留参数、工作目录、PID、信号和退出码。正式启动不新增对该工具的依赖。

已有启动脚本的接入范围如下；这不是已发布版本或整机验收清单。
游戏资源、配置和存档不因本工具迁移，运行时版本/ABI 及图形、输入适配仍沿用已有契约：

| 产品 | 正式入口 | 开发/自动化入口 |
|---|---|---|
| Unity/Rudroid 六个端口 | 保留共享 Shell 与完整匹配 kit；实验性端口保留原验收范围 | 在原脚本最外层包装一次，root 包含游戏及 PortMaster 工具路径 |
| STS2、Batomon | 保留 Godot/.NET 及原生依赖、原输入/显示流程 | 同样包装原脚本，不把引擎换成 Unity 或系统同名版本 |
| APP Manager | 保留私有 LOVE-lite 与原 PID 的游戏 exec 交接 | root 覆盖管理器、所选游戏和工具涉及的挂载；缺 PortMaster 不新增管理器引导依赖 |
| 录屏 | 保留 UI 控制与后台采帧；停止/合成需从可执行入口发起 | 后台子进程继承私有视图，测试应覆盖 UI/外层进程结束后的后续执行 |

兼容按实际能力选择：已有 exec 挂载直接透传，不要求挂载权限或厂商 SDK；
noexec 的开发入口需要 Linux mount namespace 与相应挂载能力。
无系统 Python、无挂载能力的设备继续使用原正式入口，本工具不作为游戏发行前置条件。
新增机型需验证其原有运行时/驱动与退出流程，不能以此工具的权限测试代替整机验收。

Unity 的可选私有 Wayland 路径使用 `wayland_session.py`：只有完整的
`runtime/portable-wayland` 客户端包、私有 WSI 与已安装 PortMaster Weston
通过有界预检时，才开放已验收标题的 Vulkan 选项。会话只读挂载自己的
Weston，保留系统 GPU 驱动和音频环境，游戏退出后清理；普通 GLES 和已有
Wayland 系统继续原流程。新增设备仍需验证出画面、输入、音频与退出。
