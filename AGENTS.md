# Repository agent rules

## Version discipline before the first public release

This repository has not made its first public release. Evolving internal data
formats are the current baseline, not a sequence of supported public versions.

- Never increment a Schema, Config, API, manifest, or package version unless
  the user explicitly authorizes that exact version change.
- A struct or JSON shape change alone is not permission to bump a version.
  Update the format, every in-tree consumer, and its tests in place.
- Do not add backward-compatibility readers or migrations for unpublished
  formats unless the user explicitly requests them.
- Before proposing a version bump, identify the released external consumer or
  persisted compatibility boundary that requires it. If none exists, keep the
  current version.
- Source revision hashes and rebuilt binary checksums are build identities, not
  semantic format versions; they may change when their inputs are rebuilt.

## What counts as an incompatible change

A version number identifies a compatibility contract. It may change only when
an old and a new independently deployed or persisted participant cannot safely
interoperate. Examples are:

- an old persisted document must survive an upgrade, but the new reader cannot
  safely interpret it without migration;
- old and new frontend/backend binaries can run together, but one side cannot
  parse the other side's message;
- a required field is removed or renamed, or an existing field changes type,
  units, or meaning in a way that an old participant would misinterpret.

These are not incompatible changes and must not bump a version:

- internal refactors or implementation changes;
- adding an optional/defaulted field that old readers can ignore;
- making an internal fact more precise while updating all in-tree consumers;
- changing a producer and consumer that are built and shipped together;
- changing any format that has never been publicly released or persisted as a
  supported upgrade boundary.

Incompatibility does not automatically authorize a bump. Before changing any
version, an agent must:

1. obtain explicit user approval for the exact old and new version;
2. document which old/new producer-reader combinations must work or fail;
3. implement migration, compatibility reading, or explicit version negotiation
   with a fail-closed error for unsupported combinations;
4. add tests for every supported old/new combination and the unsupported case;
5. update all producers, consumers, schemas, generated files, and release
   artifacts atomically.

If those conditions are not met, keep the current version. Never use a version
bump as a substitute for updating all in-tree consumers correctly.

## PortMaster Launcher Pack

本仓库将端口声明、共享启动模块与原生辅助程序组装为 ARM64 Linux 掌机安装包。普通游戏由 LÖVE 设置页交给 Shell 启动；APP Manager 在 Rust/LOVE-lite 内管理应用。平台事实来自 `config/`，游戏引擎由所属工程提供。

从下方清单进入模块，再阅读所属 `AGENTS.md`；文档格式与级联规则见 [FRACTAL-DOCS.md](FRACTAL-DOCS.md)。端口声明与封装入口位于 `ports/`，共享契约在所属模块维护。

### 命名与发行

- 品牌为 Jenny Loong。可见 SH 使用 `Je-游戏名.sh`，Wine 使用 `Je-Wine.sh`，APP Manager 保留原名；同名封面与安装清单同步。数据、资源和存档目录沿用各端口标识。
- 暗黑破坏神 II NS 统一使用 `d2r_ns_2g` 的 2G 适配和 `Je-暗黑破坏神II_NS（2G版）.sh`，只发行一个 NS 包。内存预设与硬件验证范围分别记录。
- 每个产品和平台保留一份当前交付。APP Manager 的 Port 与 TrimUI App 对应不同安装布局，分别封装。
- 资源分发范围、运行依赖和已验证设备以端口 README 与许可为准；正式原生产物遵循对应工程的 Release 和构建身份检查。

### 源码、输入与产物生命周期

| 内容 | 位置 |
|------|------|
| 维护源码 | `_kit/`、`ports/`、`crates/`、`config/`、测试与技术文档 |
| 本地资源输入 | `gamefiles/<title>/`；STS2 使用 `gamefiles/sts2/windows/` 与 `gamefiles/sts2/linux-baseline/`，不纳入源码或普通发行包 |
| 可重建缓存 | 构建器固定的 `.cache/<tool>/`；共享管理的 `target` 软链接按其管理器规则使用 |
| 当前实验 | `.scratch/<component>/`；既有工具的固定临时出口在任务结束时清理 |
| 端口暂存 | `ports/<port>/dist/`，组包和核验后清理 |
| 当前交付 | 根 `dist/`；迷你龙包归 `dist/miniloong/`，源码包归 `dist/source-release/`，未压缩交付归 `dist/ports/<port>/` |

1. 构建只读原始输入；真实输入测试通过显式参数或变量选择，不探测个人缓存。复用文档指定的构建环境、组件缓存与当前任务目录。
2. 中间产物写入表中固定位置，不新增逐轮目录。可重建缓存每项目以 10 GiB 为软上限，超出后评估并清理过期内容；自动回收的系统或容器夹具可照常使用。
3. 验证范围随改动选择。源码身份变化须实际重建匹配产物；设备与玩法验收单独记录，不由静态检查推定。
4. 核验后只保留每个产品/平台的一份当前压缩包或完整目录，在 `dist/ARTIFACTS.json` 记录大小与校验。清理暂存、重复解包、设备快照和候选，将稳定结论合并到对应技术说明。
5. 清理前确认归属、活动任务、唯一输入和存档，仅处理本项目已确认产物；不全局 prune、清空回收站或删除共享管理缓存。占用统计区分工程减少和实际磁盘释放。

### 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 项目说明 | `README.md` | 端口总览、构建入口、部署和授权说明 |
| 开发指南 | `CONTRIBUTING.md` | 环境、验证、交付和公共源码维护约定 |
| 分形文档协议 | `FRACTAL-DOCS.md` | 按需导航、源码头注释、目录清单与级联维护规则 |
| 共享启动/构建 | `_kit/` | Shell 公共模块、LÖVE UI、包组装及运行时构建工具 |
| 设备配置 | `config/` | 平台识别、路径、环境和管理安全策略的源片段与生成契约 |
| 原生核心 | `crates/` | PortKit、App Manager 业务/服务、LOVE-lite 与游戏启动辅助程序 |
| 产品端口 | `ports/` | 各游戏及应用的清单、启动模板、设置界面和专用兼容工具 |
| 通用掌机工具 | `handheld-lab/` | 独立于应用的设备控制器、Probe、原生 provider 与测试 |
| 管理器评估 | `lab/` | App Manager 配置/服务/UI 和设备用户态评估 |
| 仓库回归 | `tests/` | 跨模块启动器、UI、发行包和资源契约测试 |
| 生成工具出口 | `tools/` | 从 `_kit/recorder.sh` 生成的录屏 CLI，不手工编辑 |
| Rust 工作区 | `Cargo.toml` | crate 成员、共享依赖、版本与编译 profile |
| Rust 依赖锁 | `Cargo.lock` | 可复现依赖解析和构建身份输入 |
| CI | `.github/` | 桌面下载 CLI 的手动构建与两天产物保留 |
| 仓库授权 | `LICENSE` | 项目许可与非商业分发约束 |
| 忽略规则 | `.gitignore` | 排除生成目录、外部游戏数据及本机实验内容 |
| 兼容库大文件 | `.gitattributes` | 共享兼容库 ELF 使用 Git LFS，文档、清单和补丁保留普通 Git |

### 常用验证

- `cargo check --workspace --locked --offline`：使用本地依赖检查 Rust 工作区。
- `python3 config/scripts/generate.py --check`：检查生成配置与源片段一致。
- `python3 -m unittest -v config.tests.test_config_contract lab.tests.test_collect_device_evidence lab.tests.test_pam_lab`：配置及评估器回归。
- `python3 -m unittest discover -s handheld-lab/tests -v`：通用掌机工具回归，Linux 专属能力在其他主机上可能跳过。
- 其他入口先读所属目录 `AGENTS.md`；部分测试会生成发行内容或操作显式指定的设备/容器，不能视为无副作用的静态检查。
