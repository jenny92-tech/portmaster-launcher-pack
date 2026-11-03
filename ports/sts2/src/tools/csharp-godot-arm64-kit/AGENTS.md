# C# Godot ARM64 移植工具

STS2 工具树中可复用于 C# Godot 游戏的跨架构辅助工具集。检查/改写 deps 与 PE 标志，用元数据定位托管入口问题；等长 PCK 补丁补齐扩展映射，隔离引擎补丁和离线采样用于内存分析。

## 约束

- 原位补丁与显式提供的元数据及原内容、替换内容 MD5 绑定，不携带或默认选用旧游戏资源快照。
- PE machine 修补只适用于纯 IL，不把 ReadyToRun 原生代码当作架构无关。
- 游戏文件、FMOD 运行库及外部构建依赖保持既有许可和忽略边界。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| apply_gdext_patch.py | `apply_gdext_patch.py` | 校验原内容及替换内容哈希，为 FMOD 扩展加入 Linux ARM64 映射 |
| apply_pck_blob_patch.py | `apply_pck_blob_patch.py` | 经原内容和替换内容哈希校验执行幂等的 PCK 单文件原位补丁 |
| clrmeta.py | `clrmeta.py` | 用最小 ECMA-335 解析器定位游戏初始化入口 |
| patch_pe_machine.py | `patch_pe_machine.py` | 将误标为 AMD64 的纯 IL 程序集改为 ARM64 并跳过 ReadyToRun |
| peflags.py | `peflags.py` | 辅助检查程序集机器类型与 ReadyToRun 原生代码标记 |
| rewrite_deps_json.py | `rewrite_deps_json.py` | 迁移自包含 .NET 应用的运行时依赖描述到目标架构 |
| Vulkan 内存实验 | `godot-928-vma-memory.patch`、`Dockerfile.vma-trial` | 固定 Godot RC 的隔离 ARM64 构建与 VMA 保留统计候选 |
| RichTextLabel 小块试验 | `godot-928-richtext-small-pool.patch`、`richtext_pool_fixture.gd` | 局部分块候选及真实引擎长文本对照，不影响全局 RID 策略 |
| 系统字体缓存诊断 | `godot-928-system-font-diag.patch`、`system_font_diag_fixture.gd` | 仅显式开关输出新缓存文件的有界元数据，并以固定字符验证 |
| 内存分析指南 | `MEMORY-PROFILING.md` | 固定构建、采样口径、heaptrack 使用与离线汇总 |
| 原生堆模块汇总 | `heaptrack_modules.py`、`test_heaptrack_modules.py` | 离线汇总 heaptrack 1.3 模块分配、峰值与时间截取并验证事件口径 |
| README.md | `README.md` | 跨架构移植流程与各工具用法 |
| ci | `ci/` | FMOD 与 Spine ARM64 构建 workflow 示例 |
