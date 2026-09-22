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

> 面向 ARM64 Linux 掌机的游戏启动器、Port App Manager 和共享构建/设备评估工具。

> **本项目采用分形文档协议，必须遵守 [FRACTAL-DOCS.md](./FRACTAL-DOCS.md) 定义的三层文档规范；以上用户维护的版本纪律保持有效。**

### 项目定位

普通端口复用 PortMaster 的 LÖVE 设置界面与 Shell 启动流程；App Manager 通过专用 LOVE-lite 进程连接 Rust 管理核心；正式配置集中在 `config/`，发行内容由 `_kit/` 生成。

### 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 项目说明 | `README.md` | 端口总览、构建入口、部署和授权说明 |
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

### 常用验证

- `cargo check --workspace --locked --offline`：使用本地依赖检查 Rust 工作区。
- `python3 config/scripts/generate.py --check`：检查生成配置与源片段一致。
- `python3 -m unittest -v config.tests.test_config_contract lab.tests.test_collect_device_evidence lab.tests.test_pam_lab`：配置及评估器回归。
- `python3 -m unittest discover -s handheld-lab/tests -v`：通用掌机工具回归，Linux 专属能力在其他主机上可能跳过。
- 其他入口先读所属目录 `AGENTS.md`；部分测试会生成发行内容或操作显式指定的设备/容器，不能视为无副作用的静态检查。
