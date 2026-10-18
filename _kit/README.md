# 共享启动与打包工具

`ports/<name>/love/` 维护设置声明和 Shell 模板；`dist_port.sh` 组装成自包含设备入口。
只部署生成的 `ports/<name>/dist/`，设备不需要仓库 `_kit/`。

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
`rudroid.runtime/`；完整 kit 的生成/审计遵守 [Rudroid 构建指南](../../rudroid/BUILD-DOCKER.md)。
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
封面仅同步同名包资源且不覆盖现有文件；打包不包含缓存、日志、备份、存档或游戏数据。

PortKit 的 GitHub 路由按 release/raw/archive/clone/api 等能力选择并校验内容后发布，
APP 通过进程内共享库使用；普通启动器只携带声明所需的静态 helper。
最终负载由 `build_info.py` 计算内容散列和 UTC 日期；这是构建身份，不升级配置/API 版本。
发行经过 dist 入口，单独 assemble 的脚本没有完整包身份。
