# Port App Manager

Port App Manager 是一个独立的掌机软件，用于管理 Port 启动项、回收站、残留目录、
共享 Runtime 和 PortMaster 环境。它自带 aarch64 LÖVE、中文字体、gptokeyb、控制器
数据库和 HTTPS 工具，因此 PortMaster 缺失或损坏时仍能启动并完成修复。

## 功能范围

- 列出受管 Port，显示目录、图片和估算大小。
- 默认将卸载内容移动到回收站，支持恢复和明确确认后的永久删除。
- 清理无主目录、图片和失效启动脚本。
- 修复当前启动脚本声明的缺失或损坏 Runtime。
- 显示 PortMaster 版本、健康状态、设备、路径和环境详情。
- 在 MiniLoong 上安装 Jenny92 维护版 PortMaster；其他设备安装官方稳定版。
- 安装后在下一次启动时阻断式验证，失败则恢复旧的受管核心。

Port App Manager 不管理游戏本体资源，也不替代 PortMaster 的端口目录、图片、主题或
Runtime 数据源。

## 页面与输入

首页、残留页和回收站使用“左侧内容、右侧操作”。环境管理左侧显示版本、状态、设备
和路径，右侧提供检查更新、更新/重新安装、Runtime 修复和环境详情。简单的缺失、安装
后校验和恢复提示使用单栏页面，不保留空侧栏或分割线。

环境详情按“关键路径 / 环境变量 / 已安装 Runtime”分段。TextView 默认双列、自动换行
和同排等高，关键路径说明由稳定 Item ID 查询，不依赖列表下标。

UIKit 只处理语义化的确认与返回。所有危险 Dialog 默认聚焦安全操作；退出必须经过
明确按钮确认。App Manager 携带独立 `love/ui.gptk` 和 `gamecontrollerdb.txt`，不修改
其他游戏启动器的按键映射。

## 安全执行边界

Lua 负责展示、只读扫描、选择和写入 `state/plan.txt`。所有移动、恢复、删除、下载和
安装都由 `launcher.sh` 的 helper 模式执行，并重新检查路径边界。UI 不能绕过 Shell
校验直接修改文件系统。

```text
UI 选择并确认
  -> 写入 operation plan
  -> Shell 重新验证并执行
  -> 原子写入 result/progress state
  -> 当前 UI 重扫并刷新页面
```

卸载默认进入 `PortAppManager/trash/<timestamp>/`。只有卸载 Dialog 中主动勾选“直接
删除”，或在回收站中再次确认“彻底删除”，内容才会永久删除。共用同一数据目录的多个
脚本只有全部选中时才移动该目录；恢复遇到同名目标时绝不覆盖。

端口归属使用两条独立规则：精确展开脚本变量决定卸载归属；保守词边界引用决定残留
归属。解析失败只允许少清理，不能扩大删除范围。扫描会先移除注释，并拒绝把含 Shell
元字符或不含 `/ports/` 路径段的表达式当成可删除目标。

`libs`、`config`、`themes`、日志和缓存不属于 PortMaster 核心替换范围。安装器只替换
计划中声明的受管核心和前端文件，保留回滚及待验证清单。下一次启动验证成功后才删除
回滚；失败时恢复旧核心并要求退出。

## 下载与资源来源

资源地址集中在 `src/appmanager_sources.sh`：

| 内容 | 来源 | 校验 |
| --- | --- | --- |
| MiniLoong PortMaster | Jenny92 Fork stable | `SHA256SUMS` |
| 其他设备 PortMaster | 官方 PortMaster-GUI stable | 官方 `version.json` 中的 MD5 |
| App Manager 安装协议 | Jenny92 Fork 维护分支中的 `tools/appmanager-installer.sh` | 协议标记、语法和内容验证 |
| Runtime 元数据与镜像 | 官方 PortMaster-New | URL、大小、MD5 和 SquashFS 文件头 |

GitHub 下载统一使用 `_kit/github_proxy.sh`。代理按 Release、Raw、Archive、API、Gist 和
Clone 能力筛选，每批最多探测五条线路。下载成功的线路只在当前进程中优先复用；进程
退出后缓存消失。断点数据仅能从相同格式化端点继续，切换线路会丢弃不兼容的部分文件。
最终文件必须通过调用方验证，否则继续换线；全部失败后才向 UI 报错。

Runtime 页面只展示当前受管脚本通过 `runtime=` 或 `*_runtime=` 明确声明的依赖。
缺失项和无效 SquashFS 默认进入“需要修复”，本地有效项可手动选择重新下载。客户端不
携带固定 Runtime 清单；每次安装前刷新官方 `ports.json`，因此不需要跟随远端目录更新
重新发布 App Manager。

## 目录和状态

发布物只有启动 SH 和相邻资源目录：

```text
APP Manager.sh
PortAppManager/
  bin/       portable executables
  love_ui/   UIKit and application Lua modules
  runtime/   private LÖVE runtime
  share/     font, CA and controller data
  state/     plans, progress, cache and pending validation
  trash/     recoverable uninstall batches
```

MiniLoong 受管核心默认位于 `/mnt/sdcard/roms/ports/PortMaster`。TrimUI 官方布局的核心
位于 `/mnt/SDCARD/Apps/PortMaster/PortMaster`，同级前端文件为 `launch.sh`、
`config.json` 和 `icon.png`。脚本目录、游戏数据目录、核心目录和前端目录始终分别探测，
不会假设它们相同。

生产诊断写入 `log.txt`。`progress.tsv`、结果、下载缓存、回滚和待验证文件是操作状态，
不是长期调试快照。

## 构建与验证

```bash
_kit/dist_port.sh appmanager

bash tests/test_appmanager_sources.sh
bash tests/test_github_proxy_library.sh
bash tests/test_appmanager_device_gates.sh
bash tests/test_appmanager_portmaster_repair.sh
bash tests/test_appmanager_pending_validation.sh
bash ports/appmanager/tests/test_appmanager_apply_flow.sh
bash tests/test_appmanager_portable_package.sh
bash tests/test_love_shared_components.sh
```

设备发布前执行 [SMOKE_TEST.md](SMOKE_TEST.md)。跨仓库职责和 CI 产物见
[`../../docs/architecture.md`](../../docs/architecture.md)。第三方组件和来源见
[`portable/licenses/THIRD-PARTY-SOURCES.md`](portable/licenses/THIRD-PARTY-SOURCES.md)。
