# 开发指南

本仓库维护启动器、设备配置、APP Manager 和打包工具。游戏引擎在独立工程中维护；
游戏资源、玩家存档、固件采集件和本地实验输出不属于公开源码。

## 环境与目录

- Shell/Python 工具使用 Bash 和 Python 3.11+；部分端口另需 .NET、Godot 或外部运行时。
- 原生组件使用 Rust 工作区。ARM64 发行构建按 [_kit](_kit/README.md) 的容器流程执行。
- Git LFS 管理允许提交的兼容库和媒体；外部引擎、游戏及运行库按各端口说明提供。
- `_kit/` 放共享能力，`config/` 放设备策略，`crates/` 放原生实现，`ports/` 放端口差异。
- `tests/` 放跨模块回归，`handheld-lab/` 和 `lab/` 放可复用的设备评估工具。

从根 [AGENTS.md](AGENTS.md) 进入对应目录的导航，遵守
[文档协议](FRACTAL-DOCS.md)。修改源码时同步维护接口说明、所属目录清单和直接调用方。
首次公开发行前的版本纪律见根 AGENTS；内部字段调整不自行增加版本号或添加兼容迁移。

## 修改与验证

优先修改公共层，再由端口声明差异。面向玩家的入口命名为 `Je-游戏名.sh`，
APP Manager 保留原名；普通目录、内部脚本和存档路径不随展示名称改动。

按修改范围选择检查：

```sh
python3 config/scripts/generate.py --check
python3 -m unittest -v config.tests.test_config_contract
python3 -m unittest discover -s handheld-lab/tests -v
cargo check --workspace --locked --offline
```

Python UI 回归使用 Lupa 的 Lua 5.1/5.4 运行时。端口和 UI 的具体回归见各目录说明及 `tests/`。部分脚本会打包、启动容器或操作指定设备，
执行前先检查用途；文档整理无需运行游戏、采集设备或部署。提交问题时提供复现步骤、
设备/固件和构建身份、预期与实际结果，只附与问题有关的脱敏日志。

## 构建与交付

只部署构建器生成的 `ports/<port>/dist/`。正式原生产物使用 Release，保留来源、
许可证、源码修订和校验信息；不通过改写身份文件将旧二进制标记为新构建。
当前可用功能、参数和限制写入对应 README，长期设计依据放在相关模块旁。

一次性设备地址、进程号、传输回执、逐轮性能记录和个人工作路径不写入公共文档。
实验放在被忽略的 `.scratch/`、`.tmp/` 或 `.cache/`；需要进入源码树的工具应有明确入口、
可复用目的及适当验证。不要提交游戏资源、存档、凭据或未经许可的第三方二进制。

新增或修改第三方代码时保留上游声明与来源，并遵守根 [LICENSE](LICENSE) 及组件自己的许可。
