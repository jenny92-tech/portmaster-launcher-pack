# C# Godot ARM64 移植工具

> 提供托管程序集、运行时描述与原生显示链路的诊断及补丁工具。

## 地位

STS2 工具树中可复用于 C# Godot 游戏的跨架构辅助工具集。

## 逻辑

先检查/改写 deps 与 PE 标志，再使用 metadata/probe 定位托管入口问题；等长 PCK 补丁补齐扩展映射，POC/shim 诊断 Mali 显示链路。

## 约束

- 原位补丁与元数据/原内容 MD5 绑定，不能将 examples 用于未核验的游戏构建。
- PE machine 修补只适用于纯 IL，不把 ReadyToRun 原生代码当作架构无关。
- 游戏文件、FMOD 运行库及外部构建依赖保持既有许可和忽略边界；不为文档初始化执行部署或下载。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| apply_gdext_patch.py | `apply_gdext_patch.py` | 经原内容哈希校验为 FMOD 扩展加入 Linux ARM64 映射 |
| apply_pck_blob_patch.py | `apply_pck_blob_patch.py` | 经原内容哈希校验执行幂等的 PCK 单文件原位补丁 |
| clrmeta.py | `clrmeta.py` | 用最小 ECMA-335 解析器定位游戏初始化入口 |
| patch_pe_machine.py | `patch_pe_machine.py` | 将误标为 AMD64 的纯 IL 程序集改为 ARM64 并跳过 ReadyToRun |
| peflags.py | `peflags.py` | 辅助检查程序集机器类型与 ReadyToRun 原生代码标记 |
| rewrite_deps_json.py | `rewrite_deps_json.py` | 迁移自包含 .NET 应用的运行时依赖描述到目标架构 |
| README.md | `README.md` | 跨架构移植流程与各工具用法 |
| ci | `ci/` | FMOD 与 Spine ARM64 构建 workflow 示例 |
| examples | `examples/` | 与特定游戏包偏移/MD5 绑定的补丁元数据和等长 blob |
| poc-launchers | `poc-launchers/` | 显示链路及 EGL 黑名单的设备实验入口 |
| probe | `probe/` | 复现程序集解析的 .NET 控制台探针 |
| shim_egl | `shim_egl/` | 拦截 EGL/GL 查询的 native 垫片 |
