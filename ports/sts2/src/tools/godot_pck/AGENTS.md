# Godot PCK 资源处理

本目录有两条不同的数据流：对原包条目生成并校验增量覆盖，或用 GDRE 恢复工程后重新导入/打包。前者保留未替换条目，后者依赖宿主扩展能否重建资源。扫描器先提供身份与依赖目录，转换器输出候选和报告，合并器再验证父包、质量与替换闭集。

## 约束

- GDRE/Godot 工具和 work 中间目录属于外部依赖/生成物，不作为仓库源码维护。
- 覆盖包与全量重打包具有不同资源范围；缺少扩展的宿主编辑器无法完整重建原游戏资源。
- 转换脚本可改写恢复工程或删除冗余资源，原始输入与工作目录必须分离。

## 业务域清单

### 输入与扫描

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| extract_windows_sfx.py | `extract_windows_sfx.py` | 隔离解开 RAR5 自解压输入并逐文件核验 |
| compare_pck_inventory.py | `compare_pck_inventory.py` | 两包条目/纹理身份差异及可选程序集元数据 |
| scan_shader_features.py | `scan_shader_features.py` | 只读审计全包材质、shader 特征及静态依赖闭包，输出 JSON 报告 |
| 资源内存候选扫描 | `scan_memory_candidates.py` | 对给定资源路径展开静态依赖并按物理尺寸估算纹理存储，不读取进程或声称实测 RSS |
| scan_vfx_catalog.py | `scan_vfx_catalog.py` | 只读扫描全部 VFX 场景、递归依赖与低内存候选，输出资源目录与摘要报告 |

### 纹理转换与合并

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| force_vram_compress.py | `force_vram_compress.py` | 为重导入提前将无损纹理切换到 GPU 压缩模式 |
| low_texture_overlay.py | `low_texture_overlay.py` | 半分辨率增量、缓存校验与转换报告 |
| VRAM 压缩恢复 | `restore_vram_texture_inventory.py`、`restore_vram_texture.py`、`restore_vram_texture_worker.gd` | 对旧有效ASTC及新版同源资源生成保守身份目录、ASTC4×4增量和抽样质量报告 |
| 四分之一视觉纹理候选 | `quarter_texture_overlay.py`、`quarter_texture_worker.gd` | 源身份绑定的 ASTC8×8 视觉纹理增量 |
| 四分之一纹理合并门禁 | `merge_quarter_texture.py` | 父包 SHA、质量与候选闭集校验后合并 |
| 四分之一纹理精修 | `refine_quarter_texture.py`、`refine_quarter_texture.gd`、`refine_quarter_astc.cpp` | 对先前拒绝的视觉资源尝试透明加权 ASTC，保留质量门并绑定独立父包 |
| 精修纹理合并门禁 | `merge_refined_quarter.py` | 复算精修候选和质量尝试，验证源/父包身份与替换闭集后输出独立主包 |
| 纹理增量组合 | `combine_restored_texture.py` | 校验来源与逐项闭集，流式合并基础纹理覆盖和恢复增量 |
| Windows 纹理转换 | `windows_texture_overlay.py`、`windows_texture_worker.gd` | 校验导入映射，将桌面 BC 纹理转换为 ASTC 或保护性 RGBA 并生成覆盖报告 |
| low_texture_worker.gd | `low_texture_worker.gd` | 使用官方 Godot CPU 图像编解码器转换纹理 |
| merge_texture_pck.py | `merge_texture_pck.py` | 流式替换已审纹理，输出独立主包及身份清单 |
| verify_astc_8x8.sh | `verify_astc_8x8.sh` | 只读检查移动纹理重导入是否生成预期 ASTC 8x8 格式 |

### 字体与画布

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 字体缓存候选 | `strip_font_cache.py`、`strip_font_cache.gd` | 严格绑定新版源包和主包，离线清理三张简中字库预生成字号缓存并验证原始字体、参数和字形 |
| 通用字体缓存候选 | `strip_common_font_cache.py`、`strip_common_font_cache.gd` | 在既有简中结果不变的前提下，绑定当前主包并验证六张通用字体的拉丁字形和固定输出身份 |
| Mono 子集独立试验 | `subset_mono_font.py`、`subset_mono_font_worker.py`、`subset_mono_font.gd`、`subset_mono_uid_fixture.gd` | 固定原始字库及工具身份，仅委托字宽相同的CJK字形并验证完整主包UID、覆盖与字宽 |
| Mono 子集合并门禁 | `merge_mono_subset_trial.py`、`mono_subset_device_merge.py` | 固定单项字体候选，分别在宿主与隔离设备试验目录验证来源、闭集与主包结果 |
| 地图画布独立试验 | `map_canvas_trial.py`、`map_canvas_fixture.gd` | 绑定父包身份，仅缩小手写地图的物理画布并保留逻辑坐标，输出独立资源包和几何验证 |
| 字体图集候选 | `font_atlas_trial.py`、`font_atlas_trial.gd`、`font_atlas_uid_fixture.gd`、`font_atlas_corpus.py`、`font_atlas_metrics_fixture.gd`、`merge_font_atlas_trial.py` | 绑定父包身份，衡量中英字宽和图集，生成与验证单一 Medium 字体的 40/14 实验覆盖 |
| 字体预算合并门禁 | `merge_font_budget_trial.py` | 绑定父包及已审字体增量身份，验证四项闭集并流式合成独立候选 |
| 字体预算独立试验 | `font_budget_trial.py`、`font_budget_trial.gd` | 固定源和父包，保全字库并降低 SC 字体距离场范围、共享合成粗体，生成独立覆盖与覆盖率证据 |
| 简中 fallback 独立试验 | `font_fallback_trial.py`、`font_fallback_trial.gd`、`font_fallback_alias_fixture.gd`、`merge_font_fallback_trial.py` | 验证字体引用与中文覆盖，按严格身份生成和合并仅供中文比较的独立候选，用法见 README |
| 默认主题字体试验验证 | `test_bundled_theme_font.gd` | 用真实引擎验证 opt-in、中文码点、字体对象复用与自定义主题覆盖 |
| SC 字体缺字验证 | `test_sc_fallback_coverage.gd` | 在隔离的宿主进程测试三种 SC 字体的本地化覆盖和继承 fallback |
| 战斗遮罩字体修复试验 | `build_warmup_cover_trial.py`、`test_warmup_cover.gd` | 固定身份替换单个兼容脚本，并对照系统字体读取和无字回退，用法见 README |

### 恢复工程与通用资源

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| apply_overlay.py | `apply_overlay.py` | 以原包为基底应用恢复资源，保留不可重建扩展 |
| cap_particle_amount.py | `cap_particle_amount.py` | 在离线资源处理中降低粒子发射数量 |
| limit_texture_size.py | `limit_texture_size.py` | 按全局与路径规则限制移动端纹理重导入尺寸 |
| patch_project.py | `patch_project.py` | 配置恢复工程的 ASTC/ETC2 压缩目标及定制编辑器参数 |
| set_mipmaps.py | `set_mipmaps.py` | 在重导入前统一控制移动端纹理 mipmap 链 |
| strip_non_astc.py | `strip_non_astc.py` | 在重导入后移除 Mali 无法使用的 BPTC/S3TC 资源 |
| strip_sources.py | `strip_sources.py` | 在重打包前移除已被导入资源替代的冗余源图片 |
| extract.sh | `extract.sh` | 为资源压缩与覆盖补丁准备 PCK 恢复工作树 |
| reimport.sh | `reimport.sh` | 按修改后的纹理策略清理缓存并重新导入资源 |
| repack.sh | `repack.sh` | 为可完整重建的 Godot 项目提供直接重打包入口 |

### 说明与游戏方案

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| README.md | `README.md` | 覆盖/重导入流程与各转换入口 |
| bin-README.md | `bin-README.md` | GDRE/Godot 外部工具输入 |
| .gitignore | `.gitignore` | 外部工具、工作树与资源产物忽略规则 |
| patches | `patches/` | 游戏特定原路径覆盖和编排 |
