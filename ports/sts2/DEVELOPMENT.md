# STS2 开发与资源重建

玩家安装与设置见 [README](README.md)，逐工具参数见
[PCK 工具](src/tools/godot_pck/README.md)，采样方法见
[内存分析](src/tools/csharp-godot-arm64-kit/MEMORY-PROFILING.md)。

## 输入与依赖

| 已审输入 | 固定配置 | 构建入口 |
|---|---|---|
| 已准备的 ARM64/Mali 游戏数据 | `src/tools/handheld_low_profile.json` | `optimize_handheld.py build` |
| Windows v0.110.1 数据 | `src/tools/handheld_low_v110_profile.json` | `prepare_windows_game.py` 与 `build-windows` |

v0.110.1 是已审输入的版本声明，不代表官方最新版本或对来源渠道的认证。配置绑定原
PCK、DLL、deps 和已验 Linux 基线的 SHA-256；摘要标识文件，不自动证明兼容性。
自解压文件只能按压缩数据处理，不能执行外壳；解包边界见 PCK 工具说明。

资源构建需要 Python 3.11+、Pillow、官方 stable Godot 4.5.1、.NET 9 SDK、离线
Mono.Cecil 0.11.5 NuGet 缓存，以及合法游戏的引用程序集。Godot 版本必须以
`4.5.1.stable.official` 开头，设备使用的 PortMaster RC/custom 引擎不能替代此构建工具。
Windows 准备另需已验 Linux 9.0.7 runtime deps
和 Linux GodotSharp。原始数据保持不变，输出使用新的私有目录，游戏文件和报告不提交仓库。

每份已审原始输入只保留一份，规范位置从仓库根计算：

```text
gamefiles/sts2/
├── windows/Slay the Spire 2/
│   ├── SlayTheSpire2.pck
│   ├── release_info.json
│   └── data_sts2_windows_x86_64/
│       ├── sts2.dll
│       ├── sts2.deps.json
│       └── <handheld_low_v110_profile.json 的 windows_dependency_sha256 全部成员>
└── linux-baseline/
    ├── sts2.deps.json
    └── GodotSharp.dll
```

这组 Windows 准备输入不需要游戏 EXE、Windows 原生运行库、全套 BCL 或玩家状态。
Linux 基线不能用 Windows 同名文件或另一版 GodotSharp 替代。目录只是存放约定，
命令仍显式传入路径，也可指定其他私有目录；原始 PCK、程序集、依赖及基线的精确
内容校验保持不变。转换缓存、解包工作区和重复合并包均为可再生产物，不用于保存唯一源码。

Windows 导出的全部托管依赖均需检查 ILONLY、32 位要求、native entry 和 ReadyToRun。
只转换已审的 x64 纯 IL PE Machine 标记，不能把 Windows 原生代码转换成 ARM64。
即使 `--force-steam off`，JIT 仍可能解析 Steamworks 类型，依赖不能漏检。
此参数由游戏直接读取，不能放在 Godot 的 `--` 分隔符之后。

## 离线构建

先扫描，再按对应配置构建。命令从仓库根目录执行：

```sh
python3 ports/sts2/src/tools/optimize_handheld.py scan \
  --source-pck /PRIVATE/SlayTheSpire2.pck --output-dir /PRIVATE/new-scan

python3 ports/sts2/src/tools/optimize_handheld.py build \
  --source-pck /PRIVATE/SlayTheSpire2.pck \
  --game-dll /PRIVATE/game/sts2.dll --game-deps /PRIVATE/game/sts2.deps.json \
  --reference-dir /PRIVATE/references --godot /PATH/TO/Godot \
  --dotnet /PATH/TO/dotnet --nuget-cache /PRIVATE/nuget-packages \
  --output-dir /PRIVATE/new-build
```

Windows 输入使用独立入口：

```sh
python3 ports/sts2/src/tools/optimize_handheld.py build-windows \
  --windows-game-dir 'gamefiles/sts2/windows/Slay the Spire 2' \
  --linux-runtime-deps gamefiles/sts2/linux-baseline/sts2.deps.json \
  --linux-godotsharp gamefiles/sts2/linux-baseline/GodotSharp.dll \
  --godot /PATH/TO/Godot --dotnet /PATH/TO/dotnet \
  --nuget-cache /PRIVATE/nuget-packages --texture-cache .cache/sts2/textures \
  --output-dir .scratch/sts2/windows-build
```

Godot 与 .NET 只从显式参数或 PATH 选择，不搜索旧实验目录。输出目录必须尚不存在；
纹理缓存可以删除后重建，不能放入原始输入、玩家状态或唯一维护源码。

可加 `--plan` 只验证输入及展示步骤。`--texture-cache` 可复用经校验的转换结果；
`--reuse-verified-texture` 与 `--reuse-texture-report` 必须配对，仍重新校验完整身份。
Spine 源码和设备扩展二进制尚未建立独立构建绑定时，默认保留其候选纹理；
`--allow-unverified-spine-binary` 是显式接受这一限制，不表示二进制已验证。

产物包含逐资源报告、兼容补丁、独立合并主 PCK 和 `build-report.json`，绑定源码、工具、
输入、策略与输出身份。工具树变化会改变后续构建身份，旧报告仍只描述其原构建；
不能改写旧报告或活动包来宣称已重建。

## 资源与内存策略

| 策略 | 必须保留的语义与检查 |
|---|---|
| 缩小视觉纹理物理尺寸 | 保留 GST2 逻辑尺寸、flags、Atlas 坐标；字体、SDF、LUT、法线、HDR、数据和未知用途纹理保守保留 |
| Windows BC 转换为 Mali 可用格式 | 以 `.import` 路径和源路径 MD5 一一绑定，审计 ASTC/RGBA 选择、采样质量和未处理项 |
| 简化已审场景特效 | 保留 C# 根类型、工厂、位置、Task、信号与释放时序；预载不实例化缺少上下文的游戏节点 |
| 材质和 shader 规则 | 按类型/结构匹配，逐项核对差异，保留遮罩豁免和接口；未识别内容明确报告，headless 加载不等于 GPU 编译或视觉验证 |
| 图集按需加载 | 保留 essential 和常用战斗图集，验证三类查询、缺失加载、清理后重载与首击延迟 |
| 字体缓存与字库共享 | 保留覆盖、导入映射、fallback、布局和生命周期；source 路径与 imported 路径可能产生不同实例 |
| 主包在启动前合并 | 静态资源可早于 `NGame._EnterTree` 加载，不能依赖事后覆盖；其他条目逐项校验不变 |
| 主 PCK 留在 SD | 执行视图只放小兼容组件，大包复制到 tmpfs 会增加内存压力 |

quarter/refined 纹理、字体预算及 Mono 子集工具保留独立的显式输入接口。字体预算和
Mono 子集复用 `font_fallback_trial.collect_strings`，`optimize_handheld.py` 绑定相应生成工具。
父包、增量、覆盖集合与质量门禁由代码和报告约束；基础构建命令不承诺字节重现某份
既有定制合并包，也不以旧构建快照充当原始输入。字库缩小、图集名义大小及安装包大小
不能直接换算成 RSS 收益。

字体别名、粗体合成、MSDF 范围及 fallback 顺序须用完整父包 UID 缓存和两种加载顺序
验证。通用字体提前引用中文字体可能使英文菜单也加载中文字库；共享字体须复用规范
source 对象。子集需保持 cmap、advance、数字等宽和原 fallback，轮廓及复杂 shaping 仍需视觉检查。

渲染准备使用已审 shader 集、轻量场景和有界战斗预热，保留粒子、音效、伤害数字及
Spine 生命周期。不能仅凭首击等待时长归因为 shader 编译，也不能为降低数字盲目取消预热。

## 运行时与安装

SDL2/GLES 与 Wayland/Vulkan 当前使用各自匹配的引擎和 Mono bridge。
统一引擎在独立 Godot 工程研发，替换前须验证原生/托管接口、显示、输入、战斗和正常退出。
TrimUI SDL2 必须包含实际 KMSDRM 驱动；`src/scripts/build_bundled_sdl.sh` 检查驱动及 glibc 上限。
`src/scripts/assemble-launcher-pack.sh` 维护独立完整装配布局，不自动替换现用设备 profile。
来源及许可见 [MANIFEST](src/scripts/MANIFEST.md)，Godot 固定源码与补丁说明见
[引擎输入](src/external/godot/README.md)。

`deploy` / `deploy-windows` 面向显式目标和已验开发入口。先使用 `--plan`；实际操作
需提供设备、物理目录、入口摘要、构建目录和私有传输状态目录，参数以脚本 `--help` 为准。
不能将旧实验入口路径当作正式安装位置。

安装时全量验证摘要；Windows 安装器通过单一 `active-build` 绑定 main、game data、
release 和 patch，不将大包复制到 `/tmp`，不停止已有游戏或覆盖玩家档。续传状态绑定
远端文件所有权，不能丢弃状态后接管不明文件。仅在完整校验、无进程引用且显式指定后
清理已选旧包；fd/maps 检查是快照，清理期间不能并发启动或切换目标。原始游戏和正常
shader 缓存保留。

## 诊断与升级验证

详细诊断默认关闭。`SLL_INPUT_DIAG`、`SLL_TEXTURE_DIAG`、`SLL_ASSET_DIAG`、
`SLL_ASSET_DIAG_PATHS`、`SLL_MALLOC_DIAG` 等仅在明确排查时逐项开启。
UI 观察/控制另要求受控空目录 `SLL_DIAG_XDG_ROOT`、实际 `user://` 校验及分别启用
`SLL_UI_DIAG` / `SLL_UI_CONTROL`，不得指向玩家档。隔离运行仍需正确的 Vulkan layer 搜索路径。

升级不能只改摘要：重新审计 PCK 格式、导入映射、Spine/FMOD ABI、托管依赖、Cecil
注入点、shader 和资源生命周期，更新规则与测试，再在新输出目录重建。例如：

```sh
python3 -m unittest discover -s tests -p 'test_sts2_optimize_handheld.py'
python3 -m unittest discover -s tests -p 'test_sts2_prepare_windows_game.py'
python3 -m unittest discover -s tests -p 'test_sts2_subset_mono_font.py'
```

有外部输入的集成测试须经显式变量提供依赖，不因本机原始输入目录存在而自动运行。
Windows 准备的真实文件测试使用 `STS2_TEST_WINDOWS_GAME_DIR` 指向 `Slay the Spire 2`
目录，完整准备另需 `STS2_TEST_LINUX_BASELINE_DIR` 指向上述两项 Linux 基线所在目录；
不设置时保留合成检查并跳过真实输入测试。其他可选输入见 [测试导航](../../tests/AGENTS.md)。
主机检查后仍需在目标设备验证菜单、中文布局、
输入、首战、首击、设置往返及保存退出。报告同一统计口径和采样条件，不将不同进程、
随机局或 profiler 运行当作严格性能对照。逐轮进程、传输和清理记录留在私有实验目录。
