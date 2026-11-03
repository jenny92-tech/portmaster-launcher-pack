# C# Godot ARM64 移植工具

这些工具在游戏启动前处理 C# Godot 的跨架构输入：PE/deps 工具修正运行时描述，PCK 工具在身份匹配后做等长替换。固定引擎补丁和 heaptrack 汇总是独立的内存分析路径，不是普通资源准备的隐式步骤。

## 约束

- 原位补丁与显式提供的元数据及原内容、替换内容 MD5 绑定，不携带或默认选用旧游戏资源快照。
- PE machine 修补只适用于纯 IL，不把 ReadyToRun 原生代码当作架构无关。
- 游戏文件、FMOD 运行库及外部构建依赖保持既有许可和忽略边界。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| apply_gdext_patch.py | `apply_gdext_patch.py` | 校验原/替换 MD5 后补 FMOD ARM64 映射 |
| apply_pck_blob_patch.py | `apply_pck_blob_patch.py` | 已绑定元数据的等长单条目补丁与幂等校验 |
| clrmeta.py | `clrmeta.py` | 用最小 ECMA-335 解析器定位游戏初始化入口 |
| patch_pe_machine.py | `patch_pe_machine.py` | 纯 IL AMD64 → ARM64，ReadyToRun 保持跳过 |
| peflags.py | `peflags.py` | 辅助检查程序集机器类型与 ReadyToRun 原生代码标记 |
| rewrite_deps_json.py | `rewrite_deps_json.py` | 自包含应用的目标架构依赖重绑定 |
| Vulkan 内存实验 | `godot-928-vma-memory.patch`、`Dockerfile.vma-trial` | 固定 Godot RC 的隔离 ARM64 构建与 VMA 保留统计候选 |
| RichTextLabel 小块试验 | `godot-928-richtext-small-pool.patch`、`richtext_pool_fixture.gd` | 局部分块候选及真实引擎长文本对照，不影响全局 RID 策略 |
| 系统字体缓存诊断 | `godot-928-system-font-diag.patch`、`system_font_diag_fixture.gd` | 仅显式开关输出新缓存文件的有界元数据，并以固定字符验证 |
| 内存分析指南 | `MEMORY-PROFILING.md` | 引擎构建、采样口径和 heaptrack 流程 |
| 原生堆模块汇总 | `heaptrack_modules.py`、`test_heaptrack_modules.py` | heaptrack 1.3 模块/峰值/截取汇总及事件回归 |
| README.md | `README.md` | 跨架构移植流程与各工具用法 |
| ci | `ci/` | FMOD 与 Spine ARM64 构建 workflow 示例 |
