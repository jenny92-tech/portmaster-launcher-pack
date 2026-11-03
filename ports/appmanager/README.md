# Port App Manager

独立管理掌机 Port/APP 卸载、残留、Runtime 和 PortMaster 环境。
随包携带 aarch64 Rust/LOVE-lite 主程序、中文字体和控制器数据库，依赖固件的
glibc 与 SDL2；PortMaster 缺失时仍能启动。运行时范围见 [LOVE-lite](../../crates/love-lite/README.md)。

远程管理集中在独立页面：开启后可扫码，或在同一 Wi-Fi 的手机/电脑浏览器输入带配对码的完整地址。各级页面统一使用左侧功能导航；小屏通过顶栏菜单切换功能。

## 功能边界

正式构建的启动日志包含 `app.build=YYYY.MM.DD-源码短哈希`（UTC 构建日期），
用于区分内部测试包；直接 Cargo 开发构建标记为 `development`。
启动和前台操作失败时，界面显示具体原因及原始路径；失败详情显示完整的 `log.txt`
位置和反馈入口。原因不明确或处理后仍失败时，按提示提供日志，其中 `task.error`
记录任务和具体原因。首页保留最近的操作失败，同类操作成功重试后清除；启动失败可直接重新加载。
未建立的库存/APP 目录按空列表处理；启动事务恢复不会创建尚未安装的 PortMaster 目录。

每次实际扫描库存时，`log.txt` 的 `inventory.scan` 记录脚本数量、已确认数据目录关联数和
`classification_uncertain`；`inventory.diagnostic` 记录具体脚本及解析原因。
`inventory.data_policy=keep-all` 表示解析不确定导致全局保留数据目录，
`inventory.data_unlinked` 表示该脚本未确认目录关联，`inventory.data_shared` 表示共享目录
需要全部关联启动项被选中。首次加载、手动刷新和操作校验均使用同一诊断出口；
读取缓存快照不会重复输出。反馈只删 SH、保留文件夹的问题时，提供 `log.txt` 即可查看这些原因。

- 列出 Port，显示目录、图片和估算大小。
- 卸载前逐项查看完整删除路径，确认后直接删除，目录包含其全部内容。
- 清理无主 SH、数据目录、图片和 `._*` AppleDouble 文件。
- 将多个 SH 对同一目录的引用聚合显示，并默认保持未选中。
- 修复启动脚本明确声明的缺失或损坏 Runtime。
- 显示 PortMaster 版本、健康状态、设备、路径和环境信息。
- MiniLoong 安装 Jenny92 稳定版 PortMaster；其他受支持设备使用官方稳定版。

Port App Manager 不管理游戏本体内容，也不替代 PortMaster 的 Port 目录、主题、
图片或 Runtime 数据源。系统托管 PortMaster 的平台（如 ROCKNIX、TrimUI）不由 APP
安装、修复、重装或更新核心，也不改写 PortMaster 启动入口；保留 Runtime 修复、
环境诊断和 Port/APP 管理。TrimUI 的官方系统、第三方底包及外置 Ubuntu 用户态环境
各有差异，PortMaster 本体由相应环境提供方维护；APP Manager 不承诺修复这些环境。

## 页面与输入

功能导航分为已安装、安装游戏、存储清理、运行环境、远程管理和设置。已安装通过下拉框筛选全部/游戏/应用；刷新、重新扫描、扫描安装包及批量操作统一放在标题右侧，用浅紫底色突出，小屏在标题下方靠右换行。
项目详情使用并排的大号启动/卸载按钮，默认选中启动，也可进入批量卸载。安装页扫描存储卡根目录的 ZIP/7z。
存储页集中残留清理、AppleDouble 文件和非空回收站；运行环境页并列提供 PortMaster 维护、修复游戏 Runtime、环境诊断。
可用空间以纯文字容量展示，不能选中；功能入口的数量在右侧垂直居中。
PortMaster 维护页管理自身的版本、状态、安装路径和升级修复；环境诊断按游戏影响排序，关联游戏的 Runtime 异常每项扣 25 分，PortMaster 管理问题每项扣 2 分，正常或当前游戏未使用的项目不扣分，总分最低为 0。问题、正常项和完整环境详情依次显示。
远程开启/关闭与扫描操作共用右上角的浅紫色按钮，开启后显示二维码和包含配对码的地址；二维码按页面剩余空间自动放大或缩小，给完整地址留出位置。仅浏览页面不会启动服务。
语言、按键校准、教程和关于放在设置中；退出固定在主导航底部。
设置中的 A/B、X/Y 互换用于校正实体按键识别，分别保存并即时生效，重启后恢复；界面始终提示 A 确认、B 返回。
互换只调整本 APP 的控制器语义，不改校准文件、系统或游戏的映射；校准仍按设备按键标记采集。
各级页面统一使用留白、分隔线和浅紫焦点；选择列表在右侧勾选，环境字段在宽屏左右对齐，小屏和路径上下排列。
文本、确认框、密码键盘和下载进度使用实际字体高度排版，完整路径和失败信息可滚动查看。

宽屏各级页面保留左侧功能导航，页面操作固定在标题下，按文字宽度换行；小于 600 像素时采用单行顶栏菜单。默认 A 确认，B 返回；
内容页按 B 回到导航，导航中再按 B 打开退出确认，确认框按 B 留在应用。
上下移动导航焦点时立即显示对应页面，按 A 或右键进入内容，无需先确认切页。
导航文字和图标使用较大的尺寸，屏幕放不下时随焦点滚动，上下箭头提示更多入口，退出固定在底部。
子页面按返回历史回到原焦点。残留、批量卸载等子页只滚动内容，操作栏保持可见。
确认框统一左取消、右确认，默认安全操作；纯结果提示只保留一个确认按钮，B 也可关闭。退出需确认。
APP 直接读取 SDL 控制器，
优先使用 APP 私有校准，其次读取正式配置选定的 PortMaster `gamecontrollerdb.txt`，
再使用随包通用库与 SDL 已识别的固件/内置映射；不执行 PortMaster 控制脚本，不启动 gptokeyb，
不修改系统、PortMaster 或游戏的映射。Start 和 Select 不触发操作。

只有 SDL 无法提供 APP 所需方向与操作按键映射时，才自动打开按键校准；
不因控制器未列入 APP 自带数据库或重新连接而强制校准。
已有映射但按键不对时，可从设置里的“按键校准”或键盘 F2 进入，长按任意两个按钮不会触发。
按提示依次按下并松开上、下、左、右、
A、B、X、Y、Start、Select、L1、R1；全部必填，不跳过。最后测试方向，按 A 保存、X 重来。
映射只保存在 `state/controller-mappings/<GUID>.txt`，取消不会覆盖旧映射。
方向支持按钮、十字帽和居中轴，不要求摇杆。若 SDL 读不到原始输入，校准无法修复
驱动或权限问题；页面会提示检查连接。没有可用映射时不能取消；已有可用映射时，可用
A + B 取消重配并保留原映射，取消不会新建校准文件；原 Start + A 组合仍可用。

已安装项目只扫描管理根的直接条目，不递归读取游戏数据内容。安装、Runtime 修复、
卸载、恢复或删除完成后重新读取清单；不会为了显示目录大小遍历整张存储卡。

## 远程管理

每次启动 APP，远程管理默认关闭；进入页面也不会自动开启。手动打开独立页面里的开关后，
可扫码访问，也会显示带六位配对码的完整地址，例如
`http://192.0.2.10:8080/123456`（文档示例，实际地址以页面显示为准）。浏览器打开后自动配对，并从地址栏移除配对码；
也可打开根地址，手动输入地址末尾的六位配对码。配对后可上传并安装标准 Port/APP ZIP 或
7z、查看和卸载已安装项目，以及恢复或彻底删除回收站条目。
服务只监听局域网，不开启跨域访问；所有管理 API 都要求本次服务的随机
会话令牌，关闭远程管理或正常退出 APP 会立即结束服务。
切换功能页不会重复启动服务；配置重启会关闭服务，下次仍需手动开启。

上传采用流式落盘，单文件上限 4 GiB，接收前检查剩余空间；安装成功后删除上传副本。
设备锁屏后是否保留网络由固件决定，APP
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

配置使用 `config/config.json` 和 `config/platforms/<id>.json` 两层，规则见
[Config 契约](../../config/README.md)。在线候选需通过身份、版本和摘要校验；
失败或当前设备需要未知 adapter 时，继续使用随包配置。

原生分层见 [crates 导航](../../crates/AGENTS.md)。Lua 只通过进程内 `appmanager`
API 读取快照、启动/取消任务和接收事件，不执行 Shell 或用磁盘任务文件作为 IPC。
解析设备上下文失败会停止相关危险操作。
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

卸载确认按游戏或应用分组，每项列出实际删除的 SH、图片和数据目录；掌机用上下键滚动列表，
L1/R1 翻屏，长路径完整换行。底部“确认卸载”和“取消”始终可见，左右键选择，默认取消。电脑端使用可滚动清单。
确认后永久删除，不再将卸载内容移入回收站。掌机清单中的目录以 `/` 结尾，包含全部内部文件。
多个 SH 共用数据目录或图片时，只有全部关联启动项都被选中才列入删除清单；
共享路径会列在相关项目下，实际删除计划只处理一次。
关联无法确认的数据目录继续保留。清单绑定库存 revision，文件发生变化后必须重新确认。
残留清理同样在确认完整路径后永久删除，不移入回收站；通用布局默认不勾选任何项目。
掌机的存储清理页和电脑端仅在已有回收内容时显示回收站入口，供处理旧回收内容。

## 下载与资源

| 内容 | 来源 | 验证 |
| --- | --- | --- |
| MiniLoong PortMaster | Jenny92 Fork stable | 标准 `version.json` MD5 |
| 其他设备 PortMaster | 官方 PortMaster-GUI stable | 标准 `version.json` MD5 |
| 设备配置 | 本仓库 root + 当前平台 detail | 版本、身份、SHA-256、当前设备闭包 |
| Runtime 元数据与镜像 | 官方 PortMaster-New | URL、大小、MD5、SquashFS 文件头 |

下载线路和断点续传由 PortKit 统一处理，最终文件仍须通过上表的领域校验。

Runtime 页面只展示受管脚本通过 `runtime=` 或 `*_runtime=` 明确声明的依赖。
修复时读取官方 `ports.json`，由 native Runtime repair 批量下载、报告实时进度、响应
取消，并在原子替换前校验大小、MD5 和 SquashFS magic。客户端不携带固定 Runtime 清单。

## 发布布局

```text
APP Manager.sh
jenny92-appmanager/
  bin/       bundled native helpers
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
