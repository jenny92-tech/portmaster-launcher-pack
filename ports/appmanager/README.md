# Port App Manager

掌机上的 PortMaster 端口管理器。列出所有端口、卸载（连同图片和游戏目录）、清理
残留目录和图片、修复 Jenny 移植游戏的设置启动器。手柄操作，中英双语。
首页标题使用 `Port App Manager`，快捷工具栏在退出按钮上方固定显示
“开发: Bili 解腻Jenny”和 QQ 群联系方式，品牌信息不参与焦点导航。

“环境详情”只诊断 PortMaster/系统环境：显示 SH、Data、PortMaster 和
`libs/` Runtime 目录，以及 APP 自举层独立探测到的固件、分辨率、设备、手柄和映射参数。
APP Manager 不执行 PortMaster 的 `control.txt`、`mod_*.txt` 或 `get_controls`。同时显示 `PATH`、
`LD_LIBRARY_PATH`、`XDG_CONFIG_HOME`、`XDG_DATA_HOME`、剩余空间和
PortMaster `libs/` 中已安装的 Runtime。APP Manager 自身的文件不在此页展示。
详情页按“关键路径 / 环境变量 / 已安装 Runtime”三段显示；环境变量段固定保留旧版
16 项诊断值，空值明确显示“未提供”。信息 Item 可聚焦，按住上下即可连续滚动，
长路径会自动换行。三个详情段使用公共 TextView 双列网格：默认一行两个、同排等高，
长内容默认显示两行并用省略号提示，按 A 可展开/收起到最多八行；Runtime 也按每行两个
排列。详情页文字单独提高一级；左侧关键路径精简为 SH / Data / PortMaster / Runtime
路径，来源、用途、共用关系和误改风险集中显示在右侧说明卡。每个可选 Item 只声明稳定
`id`，右栏通过页面级 `sidebar_details[id]` 查询说明，不依赖列表下标，因此排序、插入和
双列重排不会串项。公共层同时支持按最小宽度自动决定列数的流式布局，供其他页面复用。

“环境管理”维持标准左右分栏：左侧将当前版本、最新稳定版、状态、设备和 PortMaster
路径按每行两项排列；右侧“维护”栏统一放置检查更新、立即更新/重新安装、Runtime 修复和
环境详情。返回继续使用 UIKit 标准的左上角按钮，不占用维护栏。

## LÖVE UI 与安全执行边界

UI 使用 `APP Manager.sh` 相邻 `PortAppManager/` 中自带的 LÖVE 11.5、完整中文字体、
经典 aarch64 gptokeyb、控制器数据库和 HTTPS 下载工具，并复用 `_kit/love` 中与其他
Jenny 启动器相同的页面、Item、按钮、焦点、双语和自适应布局组件。启动所需资源和
可写状态都从启动器相对路径解析；PortMaster 只在 UI 已具备启动条件后作为受管理环境
接受健康检查，不再是 APP Manager 自身的启动依赖。

Lua 只负责只读扫描、选择和生成 `state/plan.txt`。移动、恢复和永久删除继续由
`launcher.sh --apply-plan` 执行；Shell 会重新验证所有路径边界，不能
由 UI 绕过。

首页“残留清理”下方提供“Runtime 修复”。页面只列出被当前受管游戏 SH 明确声明的
Runtime，不展示与这些游戏无关的完整官方目录。列表分成“需要修复”和“已安装”两段：
缺失项以及 SquashFS 文件头无效的项目归入前者并默认勾选；文件头有效的项目归入后者且
默认不勾选。客户端不会用内置大小判断版本；用户可主动勾选并重新下载当前官方版本。
首页入口括号中的数字是需要修复的数量，而不是页面总项目数。
扫描器同时识别 `runtime=` 和 `java_runtime=`、`weston_runtime=` 等 `*_runtime=`
声明；一个游戏声明多个共享 Runtime 时会逐项检查，不再只记录第一个。
APP 不再随包携带 Runtime 清单。它读取 PortMaster 官方稳定版 Release 的 `ports.json`，
也就是 PortMaster 自己使用的数据源，并把解析结果缓存到 APP 的 `state/`。真正开始修复前
会再次刷新，只取当前 `DEVICE_ARCH` 和所选 Runtime 对应的 URL、大小与 MD5；官方更新
Runtime 不需要等待 APP 发版。在线刷新失败时本次修复会停止，旧状态缓存只用于页面展示，
不会被当作当前版本继续安装。下载内容缓存在 `state/runtime-cache/<official md5>/`，随包
curl 使用 `-C -` 从已有字节继续。只有大小、MD5、SquashFS 文件头全部通过后才原子替换；
失败不会破坏旧 Runtime 或已经下载的进度。
helper 只使用 APP 随包的低 glibc/musl curl、CA 证书、解压器和 SHA-256 工具；不会回退
到 PortMaster、固件恢复目录或系统下载工具。私有下载器缺失时直接失败，不会偷偷改变执行环境。

下载地址来自当次获取的官方 `ports.json`。helper 参考 NapCat Installer，
同时维护 `githubProxies` 与 `customProxies`：前者只在代理域名后拼完整 GitHub URL；
后者按服务分别构造 GitHub Release URL。jsDelivr 不支持 Release 资源，因此不进入
Runtime 下载候选。仅提供 Git 仓库克隆或当前返回 403 的 GitClone / Github Fast 不进入 Runtime
候选。Custom 候选优先，每批最多并发探测
5 个，只请求 4 字节 Range，只有返回 SquashFS `hsqs` 文件头才算成功；第一批出现可用
源后就停止继续探测。完整下载若失败，会依次尝试该批其他已验证源，最后验证并回退
GitHub 原生。完整下载在 APP 临时目录完成，重新校验文件头后以隐藏临时文件原子移动到
PortMaster `libs`；下载或安装失败都不会留下冒充已安装 Runtime 的半文件。

修复期间 helper 每秒将阶段、当前 Runtime、总项目序号、已处理/总字节数和瞬时下载速度
原子写入 `state/progress.tsv`。LÖVE UI 每 0.25 秒读取并显示进度条；代理测速、下载、
镜像校验和安装都有独立阶段提示。下载仍在后台 helper 中执行，不阻塞渲染或
手柄事件；进度文件损坏或尚未生成时，UI 安全退回普通“正在启动修复”提示。

扫描器仍只读取每个 SH 明确写出的 `runtime=...` 或 `*_runtime=...`，再与 PortMaster
`libs/` 对比；不从注释、路径或 glob 猜测依赖。目录归属仍采用 L1 精确解析与 L2
保守引用两条独立规则。

## 目录归属：这个 APP 唯一会毁数据的地方

判错就是删掉玩家的游戏。真实卡上 74 个脚本里，目录名**根本不在 `GAMEDIR=` 里**的
就有一堆：

- 变量名有 `GAMEDIR` / `gamedir` / `rundir` 三种
- 值有二次间接：`GAMEDIR="/$directory/ports/$PORT_NAME"`
- 目录名整个藏在 for 循环的候选列表里，赋值语句里一个字面量都看不到：
  `for candidate in "/$directory/ports/sts2" ...; do [ -d "$candidate" ] && GAMEDIR="$candidate"`
- 脚本名和目录名毫无关系：`A-文件管理器.sh` → `FileManager/`
- `$directory` / `$controlfolder` 不可信任外部脚本注入；launcher 根据已验证机型、
  启动器位置和受管核心位置独立生成这些值，并通过 `state/env.json` 喂给解析器

所以 `love/scan.lua` 用两条独立规则：

| | 规则 | 用途 |
|---|---|---|
| **L1 精确** | 展开 shell 变量求出脚本拥有的目录 | 驱动"卸载"（要删对） |
| **L2 保守** | 任何脚本在**词边界**上提到该目录名，就算有主 | 驱动"孤儿判定" |

L2 的解析失败只会让我们"少清一个残留项"，永远不会"多删一个游戏"。这个不对称是故意的。

真卡验证（74 个脚本）：L1 解出 71/74（其余 3 个是合法的无目录纯脚本 port），
**L1 与 L2 分歧为 0**，孤儿目录 1 个（`rainblood` —— 它遗留的孤儿图片
`Y_雨血1死镇.jpg` 独立印证了这个判断）。Lua 版本的核心解析规则已有固定样本
回归；设备更新后还会复核实际目录枚举。

还有两条实测挡下误报的规则：

- **注释必须先剥掉**：hk 脚本里一行注释 `# Tier 2: PortMaster libs/godot_4.x.squashfs`
  会让正则以为有个叫 `godot_4.x` 的依赖，然后报"缺失" —— 而 libs 里明明有 godot_4.5
- **死脚本判定要求路径里有 `/ports/` 段且名字无 shell 元字符**：否则
  `cd autoinstall`（相对路径）和 `cd $(pgrep ...)` 会各造出一个假的"死脚本"

## 删除为什么走 Shell 不走 LÖVE

UI 不直接修改文件系统；所有变更都交给同包 shell helper 再次校验。所以：

```
UI 勾选 → 写 state/plan.txt → 显示“处理中”
         → launcher.sh 重新校验并执行 → 写 state/result.txt → 当前 LÖVE UI 重扫并替换列表
```

helper 在后台执行，LÖVE 不退出、不重载；原页面持续显示
“处理中…”，新页面建好后再无空白帧替换。helper 缺失时直接提示失败，也不通过退出码重启。
helper 不执行任何 PortMaster 初始化脚本，也不重跑 `get_controls`。

首页、残留页和回收站的 Item 显示约占用空间，勾选后右侧主操作显示去重后的
内容总量；共用同一 Data 目录的多个 SH 不会重复累加。回收站的“彻底删除选中”
显示真正可释放空间；普通卸载和残留清理只是移入回收站。目录大小由 `--scan-sizes` 后台统计
并原子刷新 `state/sizes.tsv` 缓存；UI 首先读上次完整结果，不在渲染线程递归读 SD 卡。

首页卸载默认与残留清理一样，都是 **`mv` 进 `GAMEDIR/trash/<时间戳>/`**，并按 SH、
图片、Data 记住原来的根目录。首页右栏按“卸载 → 回收站 → 全选/全不选 → 残留清理 →
Runtime 修复”排列，让回收站紧跟卸载，两个维护工具下移。
首页不常驻“直接删除”按钮；点击卸载后的确认 Dialog 内提供默认不勾选的
“直接删除，不放入回收站” Checkbox。勾选后 Dialog 和确认按钮立即切换为红色不可恢复
样式，关闭 Dialog 后状态销毁，下次仍默认不勾选。独立回收站页
左侧列出可勾选的内容，右侧提供“放回选中”、“彻底删除选中”、“全选”、
“全不选”和“返回”；所有文件操作都严格跟当前勾选绑定。
与 SH 同名的图片合并在同一个启动项中，单独放回这个启动项时会一起恢复。放回时如果原位置已有
同名内容，绝不覆盖，冲突项继续保留在回收站。旧版已产生的扁平回收站批次也可
恢复。只有在首页明确启用“直接删除”并确认，或在回收站确认“彻底删除选中”时，
勾选内容才会永久删除。

成功后直接重新扫描并刷新列表；只有失败才显示一条简短提示，完整执行细节
留在 `log.txt`。回收站有内容时，首页入口变为提示色并显示圆点；
处理完成后标记随页面刷新消失。

多个 `.sh` 共用同一个游戏目录时，只选其中一部分会仅移除被选中的脚本，保留共用
目录；只有该目录关联的所有 `.sh` 都被选中时，才会把目录一起移入回收站或永久删除。

有长列表的页面统一采用“左侧内容、右侧操作”：首页、残留清理和回收站不再把
操作按钮放在列表底部。Jenny 修复固定在首页“退出”上方。每个右栏都有独立的
上下焦点链，按住可连续移动，到顶/到底停住，不会横跳回左侧 Item；左侧列表也会
连续移动并跟随滚动。“全选/全不选”只更新勾选状态，刷新后保持当前侧栏按钮焦点
和原列表滚动位置，不再跳回左上角第一个 Item。

APP Manager 采用跨掌机的保守键位：A/B 都激活当前明确高亮的选择，X/Y 返回；返回、
取消和退出始终画成可聚焦按钮，不依赖不同固件对 A/B 印字的交换方式。它维护自己的
`love/ui.gptk` 和随包 `gamecontrollerdb.txt`，不会改变其他 LOVE 启动器。

侧栏“退出”和首页 B 键都只打开普通退出提醒，不会立即离开 APP。Dialog 默认聚焦
“暂不退出”，只有用户移到“退出”并确认后才调用 `kit.quit()` 返回系统菜单。

UI 以 640×480 为最低基准，但画布始终使用设备原生分辨率，不会把
640×480 的字体贴图放大到大屏。MiniLoong 960×720 上的文字由字体引擎按最终
像素尺寸生成。大屏控件仍采用缓和放大：960×720 约为 125%，1024×960 约为
130%，额外面积用于显示更多 Item。

## 踩过的坑

- **不能执行受管环境来启动修复工具** —— `control.txt` 可能缺失、损坏或改变 shell
  变量。APP Manager 必须先用自己的运行时、字体、输入和网络工具启动，再把 PortMaster
  当作纯数据校验和修复。
- **MiniLoong 上标准的 controlfolder 探测全落空** —— 它的 PortMaster 在
  `/mnt/sdcard/roms/ports/PortMaster`。与其再硬编码一个绝对路径，不如认一个更强的
  事实：真正的启动脚本就躺在 ports 目录里，`PortMaster/` 就在它旁边。
- **MiniLoong 会重命名后执行** —— 前端把目标 SH 重命名为 `.port.sh`
  后直接执行，所以 `$0` 就是真实的当前启动脚本。生成文件操作 helper 时
  应复制 `$0`，不能把这个流程误判为 source 另一个脚本。
- **脚本目录 ≠ 游戏目录** —— LoongOS/ROCKNIX 上两者都是 `/$directory/ports`，但
  TrimUI 把 `.sh` 放 `Roms/PORTS/`、游戏数据放 `Data/ports/`。env.json 里分开记。
- **认出"我自己"不能只靠文件名** —— 前端会把脚本拷成 `.port.sh`，用户也可能改名。
  改为：任何引用了本 APP 目录名的脚本都是我们自己，不列出（否则用户能在管理器里把
  管理器卸载掉）。

## 构建 / 部署

```bash
_kit/dist_port.sh appmanager

# MiniLoong (adb)
adb push 'ports/appmanager/dist/APP Manager.sh' '/mnt/sdcard/roms/ports/APP Manager.sh'
adb push ports/appmanager/dist/PortAppManager /mnt/sdcard/roms/ports/
```

首次发布仅提供 aarch64 包。运行时、字体、输入和网络资源都属于 `PortAppManager/`；
`state/`、回收站、下载缓存和 helper 也保存在该目录内。包内不携带 Godot PCK、FRT、
hacksdl 或共享 Runtime 镜像。

设备发布前按 [SMOKE_TEST.md](SMOKE_TEST.md) 分别记录 MiniLoong 和 TrimUI 的独立启动、
修复、退出重开校验、Runtime 修复和正常管理操作。

## 排障

`state/scan_debug.json` 是每次启动时落盘的完整扫描判定（归属表 / 引用计数 / 孤儿 /
失效脚本 / runtime）。用户报"它把我游戏删了"或"它没认出某个残留项"时，先要这个文件。
