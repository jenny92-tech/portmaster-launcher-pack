# Je-Wine

面向 ARM64 Linux 掌机，采用 ROCKNIX 的 Windows 目录/脚本入口和社区 bottle.json 描述。运行器、共享运行环境、机型定义和游戏适配独立维护；游戏完整文件由玩家提供。
新安装器与全屏交接目前仅在主机和隔离容器验证，尚未完成掌机验收。

## 从零开始：没有 PortMaster，也没有 Python

当前支持的迷你龙 LoongOS 1.4.0.36 可以使用 `dist/je-wine-miniloong-starter.zip`：

1. 将整个包解压到 **SD 卡根目录**，合并包内的 `roms/`，不要再套进 `roms/ports/`。
2. 刷新系统游戏列表后，打开 **Je-Wine**。规范入口在 Windows 库；迷你龙使用 Ports 列表的桥接入口。无需安装 PortMaster、系统 Python 或 pip。
3. 打开游戏入口，把自己购买的完整 Windows 游戏文件放入 `roms/windows/<游戏id>/data/`；迷你龙的绝对路径是 `/mnt/sdcard/roms/windows/<游戏id>/data/`。EXE 就在这一层，不再多套文件夹。
4. 提示需要入口准备的版本，先按下文电脑准备步骤处理，再复制完整目录。当前龙沉的这一准备步骤仍需要电脑，不声称只复制原版 EXE 就能启动。
5. 选中已准备的游戏启动；首次自动安装所需公共环境，后续游戏复用。也可提前点 **安装 / 补齐运行环境**。

运行器自带约 30 MiB 的 `bootstrap-aarch64.squashfs`，里面是可重定位 ARM64 CPython、中文字体、控制器数据库和配套输入工具。
普通 Shell 入口先验证并只读挂载它，再用里面的解释器启动菜单，安装器因此不依赖尚未安装的系统 Python。
首次启动把映像完整校验后保存为按内容命名的私有副本，再只读挂载；应用更新不会原地改写正在使用的解释器映像。临时挂载点包含校验标识，并核对 loop backing file；SD 卡本身无需可执行权限。首次需额外约 30 MiB 缓存空间。
这份私有环境由所有游戏共用，游戏适配包不带解释器。
已安装 PortMaster 时，优先复用它的控制器映射和配套键鼠工具；缺失或工具无法启动时使用随包工具。私有解释器的启动方式不受影响。

“无需 Python/PortMaster”不等于支持所有掌机。当前机型仍需要 ARM64 glibc（输入工具最低 glibc 2.29）、系统 SDL2/SDL2_ttf、允许私有 loop/SquashFS 挂载，以及已适配的显示、输入和 GPU 环境。
其他固件先登记机型/环境并验证这些条件，不自动按 CPU 名称推断兼容。

## 全屏启动交接

打开运行器时，定位日志目录的预检只加载路径和机型定义，避免重复加载界面、安装器及游戏会话模块。
随后显示全屏等待画面，再校验本地游戏资源；校验完成后进入游戏库。

游戏库采用大封面详情与横向卡片，游戏、共享环境安装和重新扫描均可用手柄选择。方向键/摇杆上下或左右切换，A 确认，X 打开按键说明，Y 重新扫描；说明弹层内 A/B 返回列表。缺少资源时 A 打开补全说明，不启动游戏。返回列表时保留本次选择。

封面可选放在游戏 `bottle.json` 同目录的 `cover.png`，支持不大于 1024×1024 的 8 位 RGB/RGBA、非交错 PNG。没有封面或图片损坏时显示内置插画，不需要新增图像库，也不随发行包收集玩家封面。文字过长时换行或省略，不压扁字体。菜单、环境安装与游戏等待页使用同一套视觉。

菜单不再于启动前销毁；准备、安装、首次建立游戏环境期间继续显示全屏加载状态，只释放物理手柄给游戏输入助手。
公共 Wine 10 驱动补丁在首次 Wayland configure/映射前请求全屏；临时 SHM 背景使用启动器自己的加载画面，避免先弹出普通空白窗。
游戏的 Vulkan 客户端画面仍走原来的独立表面。WSI 的 Wayland 帧回调携带本次启动 token，旧状态和“进程已启动”都不会被当作本次画面交接。
普通 GDI 游戏不启用这项 GPU 会话背景策略。全屏助手移除原有 2 秒等待，并处理引擎后续恢复窗口样式的情况。
退出时保留菜单表面作为背景，等待正常关窗与 wineserver 结束后恢复菜单手柄；不强杀图形进程。

首帧回调不代表游戏已经进入可交互菜单，不显示猜测的加载百分比。
Wine 的精确来源 revision、补丁和二进制校验记录在 `runtime-sources.json`，项目补丁位于 `src/runtime-patches/`；对应完整修改源码另行提供。

## 分层与复用

| 层 | 维护位置 | 负责什么 | 不放什么 |
|---|---|---|---|
| 公共运行组件 | `src/components/catalog.json`、`runtime-sources.json` | Box64、Wine、x86 库、共享 D3D/Vulkan 实现、窗口助手的来源和固定校验值 | 游戏资源、具体机型路径 |
| 机型与家族 | `src/devices/` | 架构、屏幕、手柄、首页生命周期、数据路径，选择一个机型环境 | 游戏名、游戏补丁、D3D DLL 副本 |
| 机型环境 | `src/environments/` | ABI/运行库、GPU/显示/音频接口、系统路径，决定每种 API 用哪个共享实现 | 游戏 EXE、按键玩法、金手指 |
| 游戏适配 | `src/adapters/<id>/` | 文件与版本要求、图形 API、启动参数、游戏按键、入口/资源补丁、可选修改 | 机型名、GPU 路径、Wine/DXVK 二进制 |
| 共用电脑准备工具 | `src/preprocessors/`、`wine_game.py` | 对用户提供的文件执行有校验的本地准备 | 掌机显示适配、游戏文件 |

配置可通过 `extends` 复用同类基础配置。字典递归合并，列表由子配置整体替换；循环、超过八层或越出本类别目录的继承会被拒绝。

```text
设备：Linux ARM64 基础 → LoongOS RK3566 家族 → 迷你龙的屏幕/控制器差异
环境：Linux ARM64 基础 → 厂商 Mali-G52/Wayland → LoongOS 的音频、ICD 等路径
游戏：声明 d3d11 → 当前环境选择 dxvk-sarek → 共用一份组件
```

公共组件可声明提供多个接口。当前 Sarek 包含 D3D9/10/11 DLL；迷你龙环境只启用已有开场验证的 D3D11。
Vulkan 路径复用 Wine 与 WSI，不注入 D3D DLL；当前记录只验证过原生呈现，不代表所有 Windows Vulkan 游戏可玩。
D3D9/10 和 D3D12 在此机型尚未开放，启动时明确报缺少支持，不暗中降级到 D3D11。
其他环境可以在自己的配置中选择相同组件或新增实现，不修改游戏包。

## 分发产物

| 文件 | 内容 |
|---|---|
| `dist/je-wine.zip` | `.winecellar/wine-loongos/` 运行器、私有启动环境、机型/环境定义及组件目录，无游戏和 Wine 运行库 |
| `dist/wine-runtime-offline.zip` | 带 `je-wine-package.json` 身份清单的标准 ZIP，含固定校验的公共组件，无游戏或玩家 prefix |
| `dist/wine-game-sunken-dragon.zip` | 独立入口、`sunken-dragon/bottle.json` 与适配/按键，空 `data/` 的补文件说明 |
| `dist/je-wine-miniloong-starter.zip` | 将运行器、公共组件与游戏适配组合为直接复制到卡的入门包，不含游戏 |
| `dist/wine-presentation-sources.tar.gz` | Wine/WSI 显示适配的完整对应源码、补丁与构建记录 |
| `dist/wine-prepare-tools.zip` | 电脑端共用准备入口和固定校验的 Steamless 工具，单独提供 |

运行器、游戏适配与入门包解压到 SD 卡根目录，合并到同一张卡；离线运行环境 ZIP 可以直接放到卡根目录，由运行器识别导入，也保留解压到根目录的使用方式。这些包不是 PortMaster autoinstall 格式。`ports/wine-loongos/dist/` 是公共构建暂存目录，使用 ZIP 交付，不把暂存目录原样复制到设备。
游戏的 `bottle.json.items` 只列自己的 Windows 入口和 `<游戏id>/`，不拥有 `.winecellar/`。Ports 桥接只调用同卡 Windows 入口，不带另一份运行器。

## 安装环境

先将运行器 ZIP 和游戏适配 ZIP 解压到 SD 卡根目录。离线运行环境 ZIP **无需解压，直接复制到 SD 卡根目录**；迷你龙对应 `/mnt/sdcard/`。打开 **Je-Wine → 安装 / 补齐运行环境**，或首次启动准备好的游戏时，运行器会自动查找并导入所需组件。

ZIP 的外部文件名和扩展名不参与身份判断，可以改名；ZIP 根层必须保留构建器生成的 `je-wine-package.json`，组件内容和内部路径不改动。识别清单声明产品、包类型、ARM64 架构、兼容环境以及各组件的名字、大小和 SHA-256；这些组件必须与当前运行器内置目录一致，不能用 ZIP 自带的目录替换信任依据。没有额外私有文件头，普通 ZIP 工具仍可打开。

默认只检查 SD 卡根目录、`roms/windows/` 和 `roms/windows/.winecellar/packages/` 的直接文件，不递归扫描游戏目录。自定义库不符合 `roms/windows` 布局时不猜测卡根目录。命令行安装器的 `--offline` 也可显式指定单个 ZIP 或额外组件目录。导入只把已校验的所需组件写入私有下载缓存，不展开其他入口或脚本，不删除原 ZIP；损坏或不适用的候选会提示并跳过，有可用的匹配包时继续安装。

如果选择手工解压环境 ZIP，应完整解压到 SD 卡根目录，组件会落到 `roms/windows/.winecellar/packages/`；其中 `<组件名>-<校验标识>.tar.gz` 的名称和内容不改动。已校验的缓存与展开组件优先复用。当前自动导入支持标准 ZIP 的 Store/Deflate，不支持 7z、加密包或自定义前缀。

打开 **Je-Wine → 安装 / 补齐运行环境**，安装器将：

1. 根据 CPU 架构、固件 ID/版本、完整 device-tree 条目和设备文件选择已支持机型。
2. 检查机型环境所需的系统 SDL/GPU/控制器接口；字体由启动器自带，输入优先复用 PortMaster、随包工具兜底。
3. 根据已安装游戏的 API 需求合并组件，公共组件只取一份；优先复用已校验缓存。
4. 校验所有归档，创建并挂载私有 ext4 文件映像，再展开到新的运行库目录。
5. 未变组件通过硬链接复用文件，原子切换 `runtime` 链接，保留其他已装图形组件及独立玩家数据。游戏会话运行时禁止替换运行库。

当前目录未填写线上组件 URL，提供的是可用的离线安装材料。
安装器已经支持 HTTPS 下载；发布时构建者使用 `build-runtime.py --base-url https://<实际发布地址>/` 生成真实 URL，不能填未经发布的占位地址。
离线文件缺失、下载校验失败、固件不匹配或空间不足会明确报错，现有运行库不被替换。

初次映像为 2 GiB，还需要下载缓存空间。SD 卡不重新格式化，GPU/音频/输入服务不替换。
手工实验映像不作为发行镜像；安装器遇到旧的非受管运行库会提示保留原数据并使用新数据目录，不自动迁移玩家数据。

游戏库取 `--library`、入口导出的 `WINE_RUNNER_LIBRARY` 或机型的 `library_directory`。私有状态默认在库内 `.winecellar/state/`，可用 `--base` 或 `WINE_RUNNER_HOME` 显式指定；不改变游戏资源目录。

```text
SD卡/roms/windows/
  Je-Wine.sh
  Je-龙沉异世录.sh
  sunken-dragon/
    bottle.json                     # runner、依赖和游戏描述
    adapter.json                    # 文件版本、图形 API、游戏补丁
    input.gptk
    data/完整 Windows 文件
  .winecellar/
    wine-loongos/                   # 共用运行器与私有解释器映像
    packages/                       # 干净的离线组件归档
    state/
      runtime.ext4                   # 私有运行/玩家数据文件系统，不作为发行产物
      downloads/                     # 校验后的共享组件下载缓存
      .input/<映射校验标识>.txt       # 菜单/游戏共用的本次控制器映射快照
      launcher.log
挂载目录/
  runtime -> releases/<组件集合标识>   # 只有这个链接参与环境切换
  releases/                          # 干净运行库；不放游戏
  input/                             # 输入助手的私有执行副本
  sessions/<游戏目录标识>/work/        # 每游戏 prefix、缓存、设置、日志和存档
```

## 安装游戏适配并补文件

将游戏适配 ZIP 解压到 SD 卡根目录，会出现规范 Windows 入口与 Ports 桥接；共享列表按 Windows 库中的 `*/bottle.json` 发现游戏。
首次打开会创建该游戏数据目录并显示缺少哪些文件。玩家补入**完整 Windows 游戏目录**，包括 EXE、自带 DLL 与数据。
游戏不齐时不启动 Wine、不打开 winecfg。

龙沉适配包记录了原入口、准备后入口及关键 Unity 文件的 SHA-256，检查缺文件与不支持的版本。
入口处理在电脑上运行，输出 `.wine/Sunken Dragon.exe`，原文件保持不变。
准备工具通过 `--adapter-directory` 显式读取解压后的游戏适配目录；已有 Docker/Mono 工具镜像时使用其完整本地镜像 ID：

```sh
python3 wine-prepare-tools/wine_game.py \
  --adapter sunken-dragon --adapter-directory '/解压目录/roms/windows/sunken-dragon' \
  --game '/玩家的完整游戏目录' \
  --tools wine-prepare-tools --docker-image sha256:<完整本地镜像ID>
```

工具镜像可用随包 Dockerfile 构建，随后用 `docker image inspect --format '{{.Id}}' <镜像名>` 获取 ID。
准备时仅把单个待处理 EXE 和私有输出目录交给无网络、只读根、无 capabilities 的容器；不执行游戏。
输出必须匹配适配规则的校验值才写入玩家目录。随后把完整目录复制到掌机提示的位置。
也可直接补入适配规则认可的已准备文件；工具不下载或分发游戏。

游戏资源/金手指属于游戏规则。通用 `patches` 支持输入/输出 SHA-256、有限偏移写入和默认关闭的可选项：

```sh
python3 wine_game.py --adapter <id> --adapter-directory <游戏适配目录> \
  --game <玩家目录> --apply-patches --patch <可选补丁id>
```

资源补丁写入 `.wine/patched/`，在游戏私有 namespace 中只读覆盖；原资源不改写。
同一文件的修改需合并为一个有完整校验值的规则，未知版本拒绝应用。当前龙沉没有添加未验证的资源补丁或金手指。

无专用适配的游戏在 `roms/windows/<id>/bottle.json` 使用 `wine_runner` 声明 EXE、`graphics_api`、参数和输入配置，参考随包 `bottle.example.json`。完整资源放 `data/`；也可在 `data/wine-game.json` 显式提供启动声明。
这里只声明 API，不直接指定 Sarek、GPU 驱动或机型路径；当前会话要求 EXE 位于 `data/` 顶层。`input_mapping` 在 `wine_runner` 中时相对于 bottle 所在目录。

`runner` 支持 `default` / `wine-wow64`，均由已匹配机型环境选择固定 Wine；`deps` 支持 `dxvk` / `vkd3d-proton`，再通过显式图形 API 解析兼容实现。其他 runner 或依赖明确报缺项，不执行第三方 Shell 或任意 Winetricks verb。迷你龙尚未提供 D3D12，声明依赖不会自动获得支持。
`env` 支持游戏环境白名单，以及固定 `WINEARCH=win64`、`WINEDEBUG=-all`；不能重定向 prefix 或机型驱动。`configdir` 校验为 prefix 内的 `drive_c` 相对目录并记录到会话日志，存档随每游戏 prefix 持久化，不自动搬动或导出已有存档。社区包若只在 Shell 中声明 EXE，需要补入 `wine_runner`，不能仅复制脚本就视为已适配。
ROCKNIX 固件尚未登记已验硬件环境；目录布局兼容不等于支持该固件。

## 输入、退出与既有实机记录

机型家族配置中的 `portmaster_directories` 按顺序定位现有 PortMaster。优先选择同一目录下的 ARM64 `gptokeyb2` 和 `libinterpose.aarch64.so`，复制到私有运行目录后执行，不改写 PortMaster 安装。缺少任一文件、架构不符或助手启动失败，整对回退到随包工具；工具回退时保留已有控制器映射。

控制器映射依次加载随包数据库、PortMaster 数据库、`~/.config/SDL-GameControllerDB/gamecontrollerdb.txt` 用户覆盖、上级入口导出的数据库和 SDL 映射；后面的同 GUID 映射优先。运行器保存私有快照，菜单和游戏助手使用同一文件，避免助手使用私有 HOME 后丢失用户设置。这里只读取映射数据与已导出的 `get_controls` 结果，不执行 `control.txt` 中的系统设置；尚未运行过、只在其脚本内动态生成的映射不等于已导入。

PortMaster 负责物理按钮如何识别为 A/B、方向与摇杆；游戏适配的 `.gptk` 负责这些按钮对应哪些键鼠动作。机型路径和输入来源选择属于机型/公共输入层，游戏包无需添加 PortMaster 路径。
菜单抓取 SDL 已打开的物理手柄描述符，交接时由键鼠助手独占接管；不会停止固件输入服务。
通用映射为摇杆鼠标、A/B 左右键、X 回车、Y Esc；游戏可提供自己的完整映射。
Select+Start 请求正常关窗并等待 Wine 清理，不按进程名结束程序、不超时强杀活动图形会话。
每个游戏使用私有 prefix；原游戏、运行库和系统只读，无外网和 Linux capabilities。

此前迷你龙记录：Box64 0.4.4、Wine 10、私有 WSI 补丁及 Sarek 1.14.1 已进入龙沉标题、故事、彩色村庄并完成首战。
此前仅验证过游戏最终达到 960×720 无边框全屏、A 推进与 Select+Start 返回列表；启动过程曾出现首页和中间黑窗，不能算连续全屏验收；自由移动、存读档、后续 Steamworks 功能与完整流程仍待验证。
厂商 Weston output-capture 曾触发断言，后改用只读 KMS 取图；此前强杀图形进程也有内核等待异常，根因未认定已修复。
这些结果仅覆盖已准备环境，不能代替现用安装器的完整设备验收。

## 本地构建与验证

```sh
_kit/dist_port.sh wine-loongos
python3 ports/wine-loongos/src/scripts/dist-zip.py --dist ports/wine-loongos/dist --output dist/je-wine.zip
python3 ports/wine-loongos/src/scripts/dist-game.py sunken-dragon
python3 ports/wine-loongos/src/scripts/build-runtime.py --inputs <组件输入JSON> --output <组件目录> --offline-zip dist/wine-runtime-offline.zip
python3 ports/wine-loongos/src/scripts/dist-prepare-tools.py --input <已记录工具目录> --output dist/wine-prepare-tools.zip
python3 -m unittest discover -s tests -p 'test_wine_loongos*.py'
SDL_VIDEODRIVER=dummy python3 ports/wine-loongos/src/scripts/preview-menu.py --font <中文字体TTF> --output .cache/wine-ui-preview
```

构建输入 JSON 显式列出 box64、wine-source、wine-wayland、x86-source、xkb-source、sarek-source、wine-close、wine-borderless、wsi、xkbregistry 和 source-cache 路径。运行器打包前先用 `src/scripts/build-bootstrap.py` 从固定校验输入构建私有启动环境。
组件构建会校验已记录的来源与二进制；Wine/x86/Sarek 从固定校验的原始归档重新展开，不从设备或用过的运行映像打包。
