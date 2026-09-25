# Port App Manager

Port App Manager 是独立的掌机软件，用来管理 Port 启动项、回收站、残留、
PortMaster Runtime 和 PortMaster 环境。它随包携带只服务于 APP Manager 的
正式版 aarch64 LOVE-lite 1.x Rust 主程序、中文字体、gptokeyb 和 controller database；
PortMaster 缺失或损坏时，APP 本身仍能启动。LOVE-lite 直接
执行现有 Lua/UIKit，不携带或加载 PortMaster 的 LÖVE、LuaJIT、ModPlug、Ogg、
Theora 运行库，只要求固件提供基础 glibc 与 SDL2。它没有系统 LÖVE 回退；其他
游戏启动器则继续使用 PortMaster 自带的 LÖVE 11.5，两条运行时路径互不替换。

## 功能边界

正式构建的启动日志包含 `app.build=YYYY.MM.DD-源码短哈希`（UTC 构建日期），
用于区分内部测试包；直接 Cargo 开发构建标记为 `development`。
启动失败时，请提供应用目录的 `log.txt`，其中 `task.error` 记录任务和具体原因；
错误页面也可展开查看详情。构建标识不改变配置或 API 版本。

- 列出 Port，显示目录、图片和估算大小。
- 默认把卸载内容移入回收站，并支持恢复或二次确认后彻底删除。
- 清理无主 SH、数据目录、图片和 `._*` AppleDouble 文件。
- 将多个 SH 对同一目录的引用聚合显示，并默认保持未选中。
- 修复启动脚本明确声明的缺失或损坏 Runtime。
- 显示 PortMaster 版本、健康状态、设备、路径和环境信息。
- MiniLoong 安装 Jenny92 稳定版 PortMaster；其他受支持设备使用官方稳定版。
- 安装在单次任务内完成并立即可用；失败直接报告，修复方式是重新安装。

Port App Manager 不管理游戏本体内容，也不替代 PortMaster 的 Port 目录、主题、
图片或 Runtime 数据源。系统托管 PortMaster 的平台（如 ROCKNIX、TrimUI）不由 APP
安装、修复、重装或更新核心，也不改写 PortMaster 启动入口；保留 Runtime 修复、
环境详情和 Port/APP 管理。TrimUI 的官方系统、第三方底包及外置 Ubuntu 用户态环境
各有差异，PortMaster 本体由相应环境提供方维护；APP Manager 不承诺修复这些环境。

## 页面与输入

首页、残留页和回收站采用左侧内容、右侧操作的布局。环境管理显示版本、状态、
设备和路径，并提供检查更新、更新/重新安装、Runtime 修复和环境详情。简单提示、


危险 Dialog 默认聚焦安全操作；退出必须明确确认。APP 直接读取 SDL 控制器，
优先使用 APP 私有校准，其次使用自带 `gamecontrollerdb.txt`；不启动 gptokeyb，
不修改系统、PortMaster 或游戏的映射。Start 和 Select 不触发操作。

未知控制器自动打开按键校准。已有映射但按键不对时，可从首页“按键校准”、
键盘 F2，或同时长按两个实体按钮 3 秒进入。按提示依次按下并松开上、下、左、右、
A、B、X、Y、Start、Select、L1、R1；全部必填，不跳过。最后测试方向，按 A 保存、X 重来。
映射只保存在 `state/controller-mappings/<GUID>.txt`，取消不会覆盖旧映射。
方向支持按钮、十字帽和居中轴，不要求摇杆。若 SDL 读不到原始输入，校准无法修复
驱动或权限问题；页面会提示检查连接。首次校准不能取消；已有保存配置时，可用旧映射
Start + A 取消重配并保留旧配置。仅 APP 本地文件和自带 DB 都不能映射时自动校准，不做首次强制校准。

已安装项目只扫描管理根的直接条目，不递归读取游戏数据内容。安装、Runtime 修复、
卸载、恢复或删除完成后重新读取清单；不会为了显示目录大小遍历整张存储卡。

## 远程管理

APP 内开启远程管理后，会显示实际访问地址和一次性生成的六位配对码。浏览器端完成
配对后可上传并安装标准 Port/APP ZIP 或 7z、查看和卸载已安装项目，以及恢复或彻底删除
回收站条目。服务只监听局域网，不开启跨域访问；所有管理 API 都要求本次服务的随机
会话令牌，关闭远程管理或正常退出 APP 会立即结束服务。

远程服务与 APP 运行在同一进程中：APP 保持打开时可用，关闭 APP 时立即停止。上传采用
流式落盘，单文件上限 4 GiB，并在接收前检查剩余空间；安装成功后直接删除上传副本，
不再把 1–2 GiB 的传输文件重复塞进回收站。设备锁屏后是否保留网络由固件决定，APP
Manager 不修改系统电源策略，也不承诺锁屏期间继续传输。

ZIP 和 7z 都支持常见压缩算法及密码解压。加密包上传完成后会原地询问密码，不需要
重新上传：上传接口只返回 `ready` 或 `password_required` 及任务 ID，随后统一安装接口
接受可选密码和覆盖选择。端侧安装使用手柄虚拟键盘输入。识别和解压时会忽略 `__MACOSX`、`.DS_Store`
与 AppleDouble `._*` 等 macOS 元数据。当前不支持 RAR、分卷包和自解压包。遇到不支持
的格式、压缩算法、包结构或安全限制时，网页会显示脱敏诊断并可一键复制用于反馈；
报告只含文件名、格式、诊断代码和必要细节，不包含密码、设备绝对路径或配对信息。

ZIP 文件名会自动处理编码：优先保留 UTF-8 和有效的 Unicode 名称扩展，未声明的旧编码
按包内名称进行统计检测（包括常见 GBK/GB18030、Big5 和日文编码），不需要手动选择。
扫描、预览和实际解压共用相同规则；7z 保留其原生 Unicode 名称。无声明编码只能自动
推测，不能保证损坏或混合旧编码包的所有名称都正确；非法 UTF-8 声明、解码后的越界
路径和名称冲突会拒绝安装，不静默覆盖文件。

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
| `appmanager-core` | APP 设备上下文、资源元数据、inventory、安全文件操作、安装、Runtime 修复与缓存 |
| `appmanager-service` | 将 APP 业务组织成 snapshot、task、progress、cancel，并直接暴露为 Lua table |

生产路径中的 resolver 出错会直接停止相关危险操作，不会静默退回 Shell。Lua 只通过
`appmanager` API 读取快照、启动任务、轮询事件和请求取消，不执行命令，也不通过任务文件
与 Rust 交换消息。Rust service 向 Lua 提供内存事件；磁盘只保存配置、缓存、下载内容
以及安装过程使用的临时工作目录，Lua 不读取这些内容作为 IPC。
Shell 只解析 APP 路径，作为前端持有的父进程启动并等待 Rust 主程序，最后透传退出码。
这里不能改成 `exec`：部分掌机前端以启动脚本的生命周期管理显示和输入归属。

## 安装与恢复

安装流程只接受 native resolution 生成并再次验证的计划。归档解压到受管目录内的
临时工作目录并完成校验后，旧受管条目先经同文件系统 rename 退役到工作目录，新内容
再 rename 到位。交换过程写入同文件系统事务 journal；任一步失败会按逆序删除新条目并
恢复旧 core/frontend。进程或设备在提交点前中断时，下次启动先读取 journal 完成恢复，
不会把旧版本当作临时垃圾清掉。只有提交成功后才删除 retired 内容。错误写入 APP 的
`log.txt`；`libs`、`config`、`themes`、日志和缓存不属于
core 替换范围，`libs` 由 Runtime 修复单独管理。

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
  state/     caches, download metadata and advisory lock files
  trash/     recoverable uninstall batches
```

MiniLoong 旧固件的 Port 根位于 `/mnt/sdcard/roms/ports`；`ID=loong` 且
`VERSION_ID >= 1.4.0.0` 的 LoongOS 布局使用 `/roms/ports`。若固件将其中的
`PortMaster` 做成软链接，APP Manager 会解析并验证其
真实目标后再管理。旧固件通过专用启动器挂载 `python_3.11.squashfs`，新版
LoongOS 直接使用系统 Python 和标准 `PortMaster.sh`。TrimUI 官方布局默认 core
位于 `/mnt/SDCARD/Apps/PortMaster/PortMaster`，frontend 位于它的父目录。ROCKNIX、
JELOS 与 UnofficialOS 使用系统 frontend、core 内启动器布局，APP 不生成外层入口，
也不修改 `gamelist.xml`。

TrimUI 还可将 APP 作为系统应用放在 `/mnt/SDCARD/Apps/jenny92-appmanager`：

```sh
_kit/dist_trimui_app.sh appmanager
```

生成的 `[TrimUI App] APP Manager.zip` 可直接解压到 `/mnt/SDCARD/Apps/`。该系统 APP
不属于 Port 扫描、卸载或残留清理范围。

通用 Port 包使用同一份已验证产物生成：

```sh
_kit/dist_port_zip.sh appmanager
```

生成的 `jenny92-appmanager.zip` 可由 APP Manager 网页或端侧安装页直接识别；
`port.json` 明确绑定 `APP Manager.sh` 与 `jenny92-appmanager/`，不依赖名称猜测。

## 构建与验证

```sh
python3 config/scripts/generate.py --check
python3 -m unittest -v config.tests.test_config_contract
cargo test --workspace
_kit/build_appmanager_love_lite.sh
_kit/dist_port.sh appmanager
_kit/dist_port_zip.sh appmanager
_kit/dist_trimui_app.sh appmanager
bash tests/test_appmanager_portable_package.sh
bash tests/test_appmanager_port_zip.sh
bash tests/test_appmanager_inprocess_bridge.sh
```

真机发布前执行 [SMOKE_TEST.md](SMOKE_TEST.md)。第三方来源见
[`portable/licenses/THIRD-PARTY-SOURCES.md`](portable/licenses/THIRD-PARTY-SOURCES.md)。
