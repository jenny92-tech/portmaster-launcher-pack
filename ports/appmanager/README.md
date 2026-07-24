# Port App Manager

Port App Manager 是独立的掌机软件，用来管理 Port 启动项、回收站、残留、
PortMaster Runtime 和 PortMaster 环境。它随包携带只服务于 APP Manager 的
正式版 aarch64 LOVE-lite 1.x Rust 主程序、中文字体、gptokeyb 和 controller database；
PortMaster 缺失或损坏时，APP 本身仍能启动。LOVE-lite 直接
执行现有 Lua/UIKit，不携带或加载 PortMaster 的 LÖVE、LuaJIT、ModPlug、Ogg、
Theora 运行库，只要求固件提供基础 glibc 与 SDL2。它没有系统 LÖVE 回退；其他
游戏启动器则继续使用 PortMaster 自带的 LÖVE 11.5，两条运行时路径互不替换。

## 功能边界

- 列出 Port，显示目录、图片和估算大小。
- 默认把卸载内容移入回收站，并支持恢复或二次确认后彻底删除。
- 清理无主 SH、数据目录、图片和 `._*` AppleDouble 文件。
- 将多个 SH 对同一目录的引用聚合显示，并默认保持未选中。
- 修复启动脚本明确声明的缺失或损坏 Runtime。
- 显示 PortMaster 版本、健康状态、设备、路径和环境信息。
- MiniLoong 安装 Jenny92 稳定版 PortMaster；其他受支持设备使用官方稳定版。
- 安装在单次任务内完成并立即可用；失败直接报告，修复方式是重新安装。

Port App Manager 不管理游戏本体内容，也不替代 PortMaster 的 Port 目录、主题、
图片或 Runtime 数据源。系统托管 PortMaster 的平台（如 ROCKNIX）不由 APP
安装、重装或更新核心，只保留 Runtime 修复、环境详情和 Port 游戏管理。

## 页面与输入

首页、残留页和回收站采用左侧内容、右侧操作的布局。环境管理显示版本、状态、
设备和路径，并提供检查更新、更新/重新安装、Runtime 修复和环境详情。简单提示、


危险 Dialog 默认聚焦安全操作；退出必须明确确认。APP 自带
`love/ui.gptk` 和 `gamecontrollerdb.txt`，不修改其他启动器的按键映射。Start 和
Select 显式映射到 UIKit 不处理的 F10，因此不会触发确认或返回。

扫描结果采用 APP 进程内的细粒度 lazy cache。页面切换和选择只读缓存；安装、
Runtime 修复、卸载、恢复或删除完成后，只失效受影响的缓存。未知外部变化不会
触发后台重扫，重新启动 APP 或明确刷新才重建对应快照。

## 原生核心与配置

平台配置分为两级：

```text
config/config.json
config/platforms/<platform-id>.json
```

根文件只含共享策略、平台识别和 detail 引用；detail 含当前平台和它的机型。
根文件以 SHA-256 绑定 detail，并要求 format、schema、config version 和 platform ID
一致。随包包含根和全部 detail；在线刷新时，`appmanager-service` 通过
`portkit-core` 先用远端根识别当前平台，
只下载对应 detail，完整验证后再将 root/detail 对提升为本次远端候选。失败、降级、
摘要不一致或当前设备需要未知 adapter 时，继续使用随包配置。

生产包只有一个 Rust 主程序，其中链接了三个可独立测试的层：

| Core | 职责 |
| --- | --- |
| `portkit-core` | 设备/机型识别、路径和环境解析、配置刷新与校验、GitHub transport、通用文件原语 |
| `appmanager-core` | APP 设备上下文、资源元数据、inventory、安装事务、Runtime 修复、缓存与任务状态 |
| `appmanager-service` | 将 APP 业务组织成 snapshot、task、progress、cancel，并直接暴露为 Lua table |

生产路径中的 resolver 出错会直接停止相关危险操作，不会静默退回 Shell。Lua 只通过
`appmanager` API 读取快照、启动任务、轮询事件和请求取消，不执行命令，也不通过任务文件
与 Rust 交换消息。Rust service 向 Lua 提供内存事件；磁盘仅保存配置、缓存、下载和
可恢复的操作事务记录，Lua 不读取这些记录作为 IPC。
Shell 只解析 APP 路径并 `exec` Rust 主程序。

## 安装与恢复

安装流程只接受 native resolution 生成并再次验证的计划。归档解压到受管目录内的
临时工作目录并完成校验后，旧受管条目先经同文件系统 rename 退役到工作目录，新内容
再 rename 到位；成功后工作目录整体删除。没有回滚协议：stable 包很小，中断或断电后
的恢复方式就是重新安装，下一次安装启动时会清扫上一次的残留工作目录和历史版本遗留的
回滚/待验证文件。任务失败原因写入 `state/last-error.txt`（启动日志轮转为
`log.txt.1`，最近一次失败因此总能被诊断）。`libs`、`config`、`themes`、日志和缓存
不属于 core 替换范围，`libs` 由 Runtime 修复单独管理。

卸载默认进入 `jenny92-appmanager/trash/<timestamp>/`。只有卸载 Dialog 主动勾选
“直接删除”，或在回收站中再次确认，内容才永久删除。多个 SH 共用同一数据目录时，
必须全部选中才移动该目录；恢复遇到同名目标绝不覆盖。

## 下载与资源

| 内容 | 来源 | 验证 |
| --- | --- | --- |
| MiniLoong PortMaster | Jenny92 Fork stable | 标准 `version.json` MD5 |
| 其他设备 PortMaster | 官方 PortMaster-GUI stable | 标准 `version.json` MD5 |
| 设备配置 | 本仓库 root + 当前平台 detail | 版本、身份、SHA-256、当前设备闭包 |
| Runtime 元数据与镜像 | 官方 PortMaster-New | URL、大小、MD5、SquashFS 文件头 |

GitHub transport 按 Release、Raw、Archive、API、Gist 和 Clone 能力选择线路，分批探测，
并只在当前进程中复用成功线路。断点续传要求相同格式化端点、正确的
`Content-Range` 和相同实体标识；不满足条件时丢弃 partial 并重新下载。每个最终文件
还必须通过调用方的领域校验，全部线路失败后才向 UI 报错。

Runtime 页面只展示受管脚本通过 `runtime=` 或 `*_runtime=` 明确声明的依赖。
修复时读取官方 `ports.json`，由 native Runtime repair 批量下载、报告实时进度、响应
取消，并在原子替换前校验大小、MD5 和 SquashFS magic。客户端不携带固定 Runtime 清单。

## 发布布局

```text
APP Manager.sh
jenny92-appmanager/
  bin/       gptokeyb input helper
  config/    root config and platform details
  love_ui/   UIKit and application Lua modules
  runtime/   production APP Manager LOVE-lite Rust executable
  share/     font, CA and controller data
  state/     caches and crash-recovery transactions
  trash/     recoverable uninstall batches
```

MiniLoong 默认 core 位于 `/mnt/sdcard/roms/ports/PortMaster`。TrimUI 官方布局默认 core
位于 `/mnt/SDCARD/Apps/PortMaster/PortMaster`，frontend 位于它的父目录。ROCKNIX、
JELOS 与 UnofficialOS 使用系统 frontend、core 内启动器布局，APP 不生成外层入口，
也不修改 `gamelist.xml`。

TrimUI 还可将 APP 作为系统应用放在 `/mnt/SDCARD/Apps/jenny92-appmanager`：

```sh
_kit/dist_trimui_app.sh appmanager
```

生成的 `[TrimUI App] APP Manager.zip` 可直接解压到 `/mnt/SDCARD/Apps/`。该系统 APP
不属于 Port 扫描、卸载或残留清理范围。

## 构建与验证

```sh
python3 config/scripts/generate.py --check
python3 -m unittest -v config.tests.test_config_contract
cargo test --workspace
_kit/build_appmanager_love_lite.sh
_kit/dist_port.sh appmanager
bash tests/test_appmanager_portable_package.sh
bash tests/test_appmanager_inprocess_bridge.sh
```

真机发布前执行 [SMOKE_TEST.md](SMOKE_TEST.md)。第三方来源见
[`portable/licenses/THIRD-PARTY-SOURCES.md`](portable/licenses/THIRD-PARTY-SOURCES.md)。
