# 元气骑士_ns

Switch 1.2.0（Unity 2018.4 IL2CPP）的 ARM64 Linux 原生适配，与 Android/Rudroid 的 `soulknight` 端口分开维护。玩家入口为 `Je-元气骑士_ns.sh`，同级数据目录为 `soulknight_ns`。

## 当前用法

普通启动进入共享 LÖVE 设置页；默认 Vulkan、100%、跟随实际屏幕，后续选择会记住。

| 设置 | 支持的选择 |
|---|---|
| 图形后端 | Vulkan / OpenGL ES；分别进行真实能力预检，不可用项禁选 |
| 渲染比例 | 100% / 75% / 50%；降低实际内部尺寸，也会降低清晰度 |
| 屏幕比例 | 跟随屏幕 / 4:3 / 16:9；由原 Unity 重建相机与 UI，不拉伸旧画面 |

16:9 的内部尺寸依次为 640×360、480×270、320×180；4:3 为 640×480、480×360、320×240。
物理输出尺寸不随内部渲染比例改变。设置保存在 `love_ui/state.txt`，开始游戏时由 `launch_config.env`
传给同一 Shell 和原生 session。两份后端 ELF 与各自着色器装在同一个包内，不更换系统 GPU 驱动。

显式 `--backend vulkan|gles`、`--render-scale 100|75|50` 或 `--aspect auto|4:3|16:9` 可跳过页面直接启动；仅指定 `--profile` 仍显示页面。Select+Start 正常退出。

`--check` 在加载 SDK 前只读校验安装清单、文件和路径，不启动游戏、不接管显示、不创建存档。
`--probe-graphics` 运行有界显示预检，`--display-check` 验证显示会话往返；后二者会实际操作显示，不能当成只读检查。

截至 2026-11-16，本地源码及吹米安装已接入上述设置页与 GLES 候选，默认仍为 Vulkan。
`dist/ARTIFACTS.json` 登记的 `Je-元气骑士_ns_261114.zip` 是此前基线，尚未重出含新页面和 GLES 的完整 ZIP；不能把旧包当成本轮交付。当前实现仍有未提交修改。

## 多机型适配与启动边界

`src/launcher.sh` 复用 `portmaster_init`、`launcher_platform.sh` 和 `launcher_compat_probe`。
图形优先原生直出，失败再按实际能力补 WSI 或私有会话；不凭机型名指定显示尺寸或认定驱动可用。
Vulkan 与 GLES 独立预检；GLES 需实际通过 ES 3.2 呈现。比例取预检返回的逻辑边界，不把旋转面板模式或虚拟双缓冲高度当成屏幕尺寸。内存策略按实际 RAM 独立选择。

迷你龙的既有 Vulkan 路径复用系统 GPU 驱动及显示/音频会话，必要时补私有 WSI。
TrimUI 的 Vulkan 路径补包内 SDL/Wayland 客户端并使用受控 Weston；GLES 使用系统 SDL KMSDRM。
未知设备只有具备真实后端能力和已验证的前端接管/恢复适配器，才允许创建独占显示会话。
共享能力与驱动选择契约见 [_kit](../../_kit/README.md)。

Shell 保持官方 SDK 状态并编排音频、显示和恢复，原生 helper 管理清单、档案锁、子进程及 Weston。
UI 到游戏持续持有前端所有权，嵌套预检不提前恢复 MainUI；接管先暂停固件重启循环，再查询并停止前端。
截止时间由原生 owner 执行，GNU ABI 检查可退到系统 loader，不强依赖固件的 `timeout` / `getconf`。
普通 Bash 保留；可见桥用 `exec -a` 保持 PID 和 `.port.sh` 命令行身份。

WSI 核验会解析固件存储别名并检查库散列；会话临时根随 owner 传递，不假定固定 `/tmp`。
Release 不依赖 Python、不含调试执行视图。迷你龙远程 ADB 缺少菜单 SD 执行视图时，显式使用独立
[_kit/debug](../../_kit/debug/README.md)；调试通过不能冒充固件菜单点击验收。

## 资源、存档与低内存运行

游戏、转换模块、字体及着色器只从显式输入装配；公开软件包不包含游戏、密钥或玩家档案。
更新保留 `/userdata/soulknight_ns/profile` 或 `/mnt/UDISK/soulknight_ns/profile` 中的原档。
存在多个已有档案时用 `--profile` 明确选择，不擅自覆盖；新档只落在可写的持久存储。

TrimUI 将资源放在 SD 卡，档案与临时内存后备放在清单指定的内置存储。
模块私有文件映射及 guest 文件后备允许冷页回收；短测后备峰值约 630 MiB，入口要求至少 768 MiB
可用存储，运行中另留 128 MiB 存储余量，系统 RAM 保护独立保留 128 MiB。
临时后备退出后自动释放；这是 RAM 加存储后备方案，PSS 不能代表全部开销，慢存储仍会造成加载长帧。
热池 COW 等未取得稳定收益的候选保持关闭。原理和不变量见运行时的 `module_mapping.h`、`alias_backing.h` 及测试。

## 已验证范围

| 路径 | 有限验收 | 剩余边界 |
|---|---|---|
| MiniLoong RK3566 / Mali-G52 g13p0，Vulkan | 既有中文菜单、真正 4:3、地牢、移动/射击/技能、受伤/结算及正常退出；后续统一入口验证菜单/比例/退出 | 新设置页未重新验收；GLES 较早试验仍慢，未完成战斗验收 |
| TrimUI A523 / Mali-G57 r32p0、固件 1.0.2，Vulkan | 文件后备下菜单/大厅/地牢、移动/射击/技能、NPC 浮字及退出重进；前端重启循环受控 | 页等待造成的长帧仍存在，不承诺全关卡或长期稳定性 |
| 同一 TrimUI，GLES 候选 | 角色选择与有限真实战斗，移动/浮字/受伤/掉落/清房、正常退出 | 没有稳定 60 FPS 或整体内存下降证明；不外推 G52 |
| 2026-11-16 TrimUI 设置页 | 页面、输入、保存、UI→游戏交接；GLES 75%/16:9 为 480×270，Vulkan 50%/4:3 为 320×240，页面选 GLES 75%/4:3 为 480×360；均正常退出并回收子进程 | 使用独立档案副本，原档未改；本轮未扩展战斗或其它设备验收 |

后台 MainUI 进程恢复已记录，实体主页显示/方向键恢复未获本轮确认；扬声器听感、全关卡与长期稳定性仍需分别验收。
逐轮帧率、GPU 字节/像素与屏障证明归 [运行时说明](https://github.com/jenny92-tech/nx-linux/blob/HEAD/dm/linux/soulknight_ns/README.md)
及 [Bogodroid 性能专题](https://github.com/jenny92-tech/Bogodroid/blob/knowledge-base/docs/soulknight-ns-vulkan-performance.md)，不在本端口重复维护一套性能记录。

## 开发与组包入口

- 引擎、NS/NVN、比例补丁、文件后备与 GPU 回归归 [d2r-mobile](https://github.com/jenny92-tech/nx-linux) 的 `dm/linux/soulknight_ns`；本端口只装配资源、启动与交付。
- `src/package.py` 从显式准备目录、清单和运行时工程组装私有安装；Vulkan 的便携会话依赖由 `--portable-wayland` 显式提供。`--gles-shaders` 必须是完整的 627 阶段 GLSL bank，两份后端运行时须匹配同一源码身份。
- `src/export.py` / `src/unify.py` 保留资源散列和真实 Release 身份门禁；导出排除存档、身份、缓存、日志、个人设置与调试工具。不通过改写身份文件冒充重建。
- 启动、桥接与组包回归在 `tests/test_export.py`、`tests/test_unify.py`，共享生命周期/显示能力回归在 `_kit` 与 `crates/portkit-launcher/tests`；统一维护检查见 [CHECKS](../../CHECKS.md)。

在仓库根先执行 `cargo build -p portkit-launcher --bins --locked`，再运行
`python3.13 -B -m unittest discover -s ports/soulknight_ns/tests -p 'test_*.py'`。
组包夹具使用这份宿主 helper，不依赖本机未公开的 ARM64 调试构建或真实游戏文件。

2026-11-13 的设备专用入口、深层侧车和逐轮候选均为历史布局，当前使用一个可见 SH 和一个同级数据目录。
原设备保留的旧安装不作为新组包输入；调试回执与可恢复备份仅留在本地 `.scratch/`，不进入玩家包或公开源码。
