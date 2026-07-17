# APP Manager

掌机上的 PortMaster 端口管理器。列出所有端口、卸载（连同图片和游戏目录）、清理
残留目录和图片、修复 Jenny 移植游戏的设置启动器。手柄操作，中英双语。

“环境详情”只诊断 PortMaster/系统环境：显示 SH、Data、PortMaster 和
`libs/` Runtime 目录，以及 `control.txt` / `mod_*.txt` / `get_controls`
提供的固件、分辨率、设备、手柄、提权和映射参数。同时显示 `PATH`、
`LD_LIBRARY_PATH`、`XDG_CONFIG_HOME`、`XDG_DATA_HOME`、剩余空间和
PortMaster `libs/` 中已安装的 Runtime。APP Manager 自身的文件不在此页展示。
所有信息都是可聚焦 Item，按住上下即可连续滚动，长路径会自动换行。

## Runtime 检测与启动器修复

这个 port 自带 `runtime/frt_3.6.squashfs`，挂自己那一份来跑 UI，**完全不读
PortMaster 的 `libs/`**。

只读取每个 SH 明确写出的 `runtime=...`，再与 PortMaster `libs/` 中的文件对比；
不从注释、`libs/` 路径或 glob 猜测依赖。缺失时，只在对应游戏 Item 的第二行以
红字提示，不在右栏做全局环境报告。

右栏的“Jenny 移植游戏启动器修复”是独立的快捷工具。部分移植游戏的设置启动页
依赖内置的 `frt_3.6`；缺少它时脚本会跳过设置页、直接启动游戏。修复功能只是把
APP 随附的这一份组件复制到 `libs/`，恢复设置页，不负责修复其他 Runtime。用户界面
不显示 `frt` 文件名或修复载荷等实现细节。

## 目录归属：这个 APP 唯一会毁数据的地方

判错就是删掉玩家的游戏。真实卡上 74 个脚本里，目录名**根本不在 `GAMEDIR=` 里**的
就有一堆：

- 变量名有 `GAMEDIR` / `gamedir` / `rundir` 三种
- 值有二次间接：`GAMEDIR="/$directory/ports/$PORT_NAME"`
- 目录名整个藏在 for 循环的候选列表里，赋值语句里一个字面量都看不到：
  `for candidate in "/$directory/ports/sts2" ...; do [ -d "$candidate" ] && GAMEDIR="$candidate"`
- 脚本名和目录名毫无关系：`A-文件管理器.sh` → `FileManager/`
- `$directory` / `$controlfolder` 是 PortMaster 的 `control.txt` 注入的，脚本里
  根本没有 —— 所以解析器必须由 launcher.sh 喂进这些值（`conf/env.json`）

所以 `scan.gd` 用两条独立规则：

| | 规则 | 用途 |
|---|---|---|
| **L1 精确** | 展开 shell 变量求出脚本拥有的目录 | 驱动"卸载"（要删对） |
| **L2 保守** | 任何脚本在**词边界**上提到该目录名，就算有主 | 驱动"孤儿判定" |

L2 的解析失败只会让我们"少清一个残留项"，永远不会"多删一个游戏"。这个不对称是故意的。

真卡验证（74 个脚本）：L1 解出 71/74（其余 3 个是合法的无目录纯脚本 port），
**L1 与 L2 分歧为 0**，孤儿目录 1 个（`rainblood` —— 它遗留的孤儿图片
`Y_雨血1死镇.jpg` 独立印证了这个判断）。设备上 GDScript 的判定与 Python 原型
逐条对账，**0 处分歧**。

还有两条实测挡下误报的规则：

- **注释必须先剥掉**：hk 脚本里一行注释 `# Tier 2: PortMaster libs/godot_4.x.squashfs`
  会让正则以为有个叫 `godot_4.x` 的依赖，然后报"缺失" —— 而 libs 里明明有 godot_4.5
- **死脚本判定要求路径里有 `/ports/` 段且名字无 shell 元字符**：否则
  `cd autoinstall`（相对路径）和 `cd $(pgrep ...)` 会各造出一个假的"死脚本"

## 删除为什么走 shell 不走 Godot

卡是 exFAT 以 `uid=0` 挂的，port 脚本靠 `$ESUDO` 提权，而 Godot 是它的子进程拿不到
root，直接删会失败。所以：

```
UI 勾选 → 写 conf/plan.txt → 显示“处理中”
         → launcher.sh 用 $ESUDO 执行 → 写 conf/result.txt → 当前 FRT 内重扫并替换列表
```

helper 在后台执行，FRT 和 Godot 场景都不退出、不重载；原页面持续显示
“处理中…”，新页面建好后再无空白帧替换。helper 缺失时直接提示失败，也不通过退出码重启。
helper 只复用 `control.txt` 提供的环境，不重跑 `get_controls`；后者在部分固件会弹出并关闭全屏启动图。

首页、残留页和回收站的 Item 显示约占用空间，勾选后右侧主操作显示去重后的
内容总量；共用同一 Data 目录的多个 SH 不会重复累加。回收站的“彻底删除选中”
显示真正可释放空间，因为卸载和残留清理只是移入回收站。目录大小由 `--scan-sizes` 后台统计
并原子刷新 `conf/sizes.tsv` 缓存；UI 首先读上次完整结果，不在渲染线程递归读 SD 卡。

首页卸载和残留清理一律是 **`mv` 进 `GAMEDIR/trash/<时间戳>/`**，并按 SH、图片、Data
记住原来的根目录。首页右侧只放一个带数量的“回收站”入口；独立回收站页
左侧列出可勾选的内容，右侧提供“放回选中”、“彻底删除选中”、“全选”、
“全不选”和“返回”；所有文件操作都严格跟当前勾选绑定。
与 SH 同名的图片合并在同一个启动项中，单独放回这个启动项时会一起恢复。放回时如果原位置已有
同名内容，绝不覆盖，冲突项继续保留在回收站。旧版已产生的扁平回收站批次也可
恢复。只有用户确认“彻底删除选中”时，勾选内容才会永久删除。

成功后直接重新扫描并刷新列表；只有失败才显示一条简短提示，完整执行细节
留在 `log.txt`。回收站有内容时，首页入口变为提示色并显示圆点；
处理完成后标记随页面刷新消失。

多个 `.sh` 共用同一个游戏目录时，只选其中一部分会仅移除被选中的脚本，保留共用
目录；只有该目录关联的所有 `.sh` 都被选中时，才会把目录一起移入回收站。

有长列表的页面统一采用“左侧内容、右侧操作”：首页、残留清理和回收站不再把
操作按钮放在列表底部。Jenny 修复固定在首页“退出”上方。每个右栏都有独立的
上下焦点链，按住可连续移动，到顶/到底停住，不会横跳回左侧 Item；左侧列表也会
连续移动并跟随滚动。

UI 以 640×480 为最低基准，但画布始终使用设备原生分辨率，不会把
640×480 的字体贴图放大到大屏。MiniLoong 960×720 上的文字由字体引擎按最终
像素尺寸生成。大屏控件仍采用缓和放大：960×720 约为 125%，1024×960 约为
130%，额外面积用于显示更多 Item。

## 踩过的坑

- **`control.txt` 会把 `SCRIPT_DIR` 清空** —— PortMaster 内部也用这个变量名。用
  通用名字在 source 之后必然被踩掉（实测 `[$SCRIPT_DIR]` → `[]`）。所以本脚本用
  私有名 `PAM_DIR`，且在 source 之前就求好。
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
ports/appmanager/src/scripts/fetch_runtime.sh   # 拉 frt_3.6.squashfs (12MB, 不进 git)
_kit/dist_port.sh appmanager

# MiniLoong (adb)
adb push 'ports/appmanager/dist/APP Manager.sh' '/mnt/sdcard/roms/ports/APP Manager.sh'
adb push ports/appmanager/dist/bootstrap.pck    /mnt/sdcard/roms/ports/appmanager/
adb push ports/appmanager/dist/appmanager.gptk  /mnt/sdcard/roms/ports/appmanager/
adb push ports/appmanager/dist/hacksdl          /mnt/sdcard/roms/ports/appmanager/
adb push ports/appmanager/dist/runtime          /mnt/sdcard/roms/ports/appmanager/
```

体积：pck 13.9MB（几乎全是中文字体 —— 端口名是任意中文，字体不能子集化）
+ frt 12MB ≈ 26MB。

## 排障

`conf/scan_debug.json` 是每次启动时落盘的完整扫描判定（归属表 / 引用计数 / 孤儿 /
失效脚本 / runtime）。用户报"它把我游戏删了"或"它没认出某个残留项"时，先要这个文件。
