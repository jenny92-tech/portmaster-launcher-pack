# Shell 路径后端

## 实现边界

`shell_paths.rs` 提供公开结果，`shell_eval.rs` 使用 tree-sitter-bash 语法树进行受限抽象求值，`shell_sources.rs` 提供显式只读输入。
不启动 Bash/sh、不运行游戏、命令替换或原始 source。已展开为确定文本的 eval 也仅重新交给同一个 Rust 求值器。
Node 只用于离线采集工具，不是产品运行依赖。

支持顺序赋值、引号/空格/拼接、部分参数展开、if/连续 elif/else、短路条件、部分 case、有限 for、函数与 local 赋值、
递归 source、空命令前缀、命令替换中的引用收集及 EXIT trap 引用。
未实现完整 Shell 语义：算术、交互/无界循环、数组、复杂字段拆分/通配符、source 位置参数和部分声明属性仍会阻止确定性判断。

纯等待例外：仅在 AST 可证明整个循环由未被函数覆盖的 `sleep`、单目标 `kill -0` 探测、`true/false/:` 及受限组合组成时，将未执行的等待记入 notes，不清空已知变量/cwd，也不阻断路径关联。只接受无副作用的参数展开及字面 `/dev/null` 输出；赋值、source、外部未知命令、命令替换、参数赋值、文件写入、未知重定向等均不适用。单独的相同 sleep/探测命令也不因未知时长或 PID 阻断路径。退出状态仍未知，后续条件分支必须合并；没有假定等待成功或一定结束。这不是通用数据流污点分析，也没有放宽其他诊断或证明任意外部命令安全。

结果区分实际使用的路径候选、声明提示、工作目录、LD_LIBRARY_PATH、LD_PRELOAD、输入配置、输出文件、source 文件和 Runtime 名称。
声明提示可以保护目录，但不能单独授权数据删除。输出日志不作为游戏数据引用。
Runtime fallback 使用 AST 求值得到的传统 runtime 声明，不再使用旧的逐行文本搜索；有效 port.json 优先于这些变量名提示。

配置输入：服务直接取已解析的 `paths.shell_directory` 注入 `directory`，取 PortMaster 根注入 `controlfolder`，不按目录名猜卡根。空路径不注入已知空字符串。唯一确定的托管工作目录优先选作主目录并读取其 port.json；多个共享候选不能按字典序抢占主目录，所有引用仍保留清理保护。声明和参数中的冒号路径均保留原串及拆分提示。

设备归属仅以 `context.roots.game_dirs` 为边界：按已解析路径的托管祖先关联直接子目录，不再截取 `ports` 后的名字、不跳过 `data/gamedata`、不取路径末段猜游戏名。同名异卡路径不能选择本地 port.json，也不能计入本地引用。缺失目录必须能定位到已确认根的子目录；不确定语法仍阻止残留清理。同一脚本的相同路径只解析一次，并复用于工作目录判定。

ZIP/7z 尚无目标设备上下文，其关联规则移至 `port_zip.rs`，与设备归属隔离：支持脚本所在虚拟目录、`$directory/ports`、`/roms/ports`、`/ports` 的明确包布局。任意其他绝对前缀不再因包含 `ports` 或同名末段而被猜中；自定义硬编码路径包可能因此显示无法识别，需要未来显式传入目标布局，不能把包内推测用于设备删除。`ports/data/gamedata` 本身均可作为普通游戏目录名，不隐式剥掉中间层。

Runtime 位置解析由显式 SourceEnvironment 提供：生产环境只做文件系统元数据解析，快照使用已声明的链接及完整性事实，不读取宿主路径。未知或循环链接不形成候选。

Runtime 路径关联与游戏目录关联共用 PathAnalysis：不论变量名，仅托管 libs 根下直接的 `<名称>.squashfs` 提供可下载镜像候选。PortMaster 的 `runtimes/<名称>/…` 是随包内容，只保留普通路径事实，不转换成同名镜像，也不进入本功能的下载、缺失检查或更新流程。绝对路径的冒号列表（如 Java classpath）逐项保留；声明路径、实际引用和 source 路径可补充 port.json（包括空声明），但输出专用路径不作为输入。不得把任意游戏目录中的 `libs` 当官方目录。既有祖先解析软链接、保留缺失尾部；越界子链接、断链及未解析的 `..` 不用于关联。

这些名称进入现有 Runtime need/facts 和修复链路；修复必须匹配官方元数据中的名称及架构，再按原有大小/MD5 校验和事务替换执行。不从脚本生成下载 URL，也不因目录引用宣称所有内部库已检查；仅引用整个共享 libs 目录无法推导其中具体 Runtime。新增回归覆盖变量改名、递归 source、classpath、空元数据补充、软链接与缺失文件，以及路径候选到校验修复和无匹配时禁止下载。

## 扫描性能

- 语法树按当前读取到的完整内容缓存，线程局部 LRU 最多 128 项，按文本长度及节点数量估算的 8 MiB 预算淘汰（不是实际 RSS 硬上限）。不缓存变量、函数执行结果、设备事实或读取失败；source 内容仍重新安全读取，变化会使用新树。解释步数、累计字节和深度限制在命中缓存时仍执行。
- 工作目录归属按路径一次收集托管祖先名称，复用于主目录选择和删除资格检查，不再逐个游戏目录反复 canonicalize。仍保留缺失子目录、软链接及共享目录的原有保守规则。

## 输入与安全约束

- 生产扫描只允许从已解析的 scripts、game_dirs、PortMaster 根加载源文件。
- Unix 使用 openat/O_NOFOLLOW 逐级加载，拒绝目录内软链接、越界、非普通文件及超大文件。
- 允许 .sh/.txt/.inc 及明确的 tasksetter/fallback 文件名；不泛读 HOME、系统配置或宿主环境。
- 单文件 256 KiB，累计解析文本 4 MiB，源递归 16 层；另有限制解析时间、求值深度/步数、变量及证据数量。
- 未知值不会伪装为空字符串或命令成功。缺少输入、语法错误、被分析脚本修改过的 source 和预算超限保留诊断。
- 对目录别名只接受实际可确认的关系；不擅自折叠可能跨软链接的 ..。
- 同名本身不建立目录关联。元数据选择、引用计数及删除关联均核对当前托管根的实际路径或已解析别名；托管根内的词法路径另作保守清理保护。
- source 引用的共享辅助目录计入保护；不确定脚本继续阻止残留目录推断。
- 这不是完整 Shell 沙箱或形式化安全证明，也不保证所有外部程序的文件副作用均可静态建模。

`SourceEnvironment` 将文件、存在性、命令输出/状态和别名作为显式输入。测试用 `SnapshotEnvironment` 的 complete 表示该**合成快照**
可把未列项视为不存在，不代表真实设备已扫描完整。生产 FileEnvironment 不采用这一假设；托管范围外的设备信息仍未知。
生产扫描不依赖离线 mock、硬编码 CFW 名称或初始化完成标记，离线覆盖数字不能套用到实机。

## 语料回归与复现

外部语料由运行者单独准备，不随源码包分发。基线来源为：

- PortMaster-New：`d86dcdb78891f452bebbece2a9f273c778d9721c`，包含 1445 份 SH（1438 份顶层启动器、7 份内部辅助脚本）。
- PortMaster-GUI：`3eb046956481a464b45c556c7c5d4438975d4226`，提供控制链、LÖVE runtime、tasksetter 和 patcher 等只读输入。

官方语料测试使用显式合成的 TrimUI/aarch64 上下文，以 port.json 的非 SH 成员交叉检查路径候选；
它没有还原完整游戏资源、全部 Runtime 或真实设备状态。匹配清单成员、找到库或输入配置路径，
均不等于脚本语义完全确定、控制映射可用或具备自动删除资格。包含公共 gamecontrollerdb 的引用也不能证明每份游戏键盘映射均已验证。

专项回归覆盖中文文件名、递归 source、未初始化的 device_info、大小写差异及未知外部输入。
未知文件和未建模语法继续保留诊断，不能编造空文件或成功结果来提高通过数量。

```sh
cargo test -p appmanager-core --locked --offline
cargo test -p appmanager-service --locked --offline -- --test-threads=1

PM_CONTROL_CORPUS=/path/to/control-fixtures \
PM_SHELL_CORPUS=/path/to/port-scripts \
PM_METADATA_CORPUS=/path/to/port-metadata \
cargo test -p appmanager-core official_ --locked --offline -- --include-ignored --nocapture
```

外部语料回归为显式运行项；当前结果以实际测试输出为准，不将离线覆盖数量作为实机支持率。
主要边界仍包括外部命令参数/返回值、无界循环、未建模字段拆分与通配符、设备别名和缺失输入文件。
