# Godot PCK 资源处理

STS2 移植工具中的通用资源处理流水线与游戏专属方案入口。extract 恢复项目，Python 工具调整尺寸/压缩/mipmap，reimport 生成设备纹理，strip 工具裁剪冗余内容，apply_overlay 或 repack 输出资源包。

## 约束

- GDRE/Godot 工具和 work 中间目录属于外部依赖/生成物，不作为仓库源码维护。
- 优先理解覆盖与全量重打包的区别；缺少扩展的宿主编辑器无法完整重建原游戏资源。
- 多数脚本会写项目或删除冗余资源，验证文档只做解析/静态检查，不直接运行转换流水线。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| apply_overlay.py | `apply_overlay.py` | 将恢复资源覆盖到原始包并保留无法重建的扩展资源 |
| extract_windows_sfx.py | `extract_windows_sfx.py` | 在 macOS 隔离解包玩家提供的 RAR5 自解压包，逐文件校验并保存私人报告 |
| compare_pck_inventory.py | `compare_pck_inventory.py` | 只读比较两份 PCK 条目身份和纹理格式，并可记录 DLL 与版本元数据 |
| cap_particle_amount.py | `cap_particle_amount.py` | 在离线资源处理中降低粒子发射数量 |
| force_vram_compress.py | `force_vram_compress.py` | 为重导入提前将无损纹理切换到 GPU 压缩模式 |
| scan_shader_features.py | `scan_shader_features.py` | 只读审计全包材质、shader 特征及静态依赖闭包，输出私有 JSON |
| 资源内存候选扫描 | `scan_memory_candidates.py` | 对给定资源路径展开静态依赖并按物理尺寸估算纹理存储，不读取进程或声称实测 RSS |
| scan_vfx_catalog.py | `scan_vfx_catalog.py` | 只读扫描全部 VFX 场景、递归依赖与低内存候选，输出私有目录和摘要 |
| low_texture_overlay.py | `low_texture_overlay.py` | 构建私有半分辨率纹理覆盖包并验证缓存和报告 |
| VRAM 压缩恢复 | `restore_vram_texture_inventory.py`、`restore_vram_texture.py`、`restore_vram_texture_worker.gd` | 对旧有效ASTC及新版同源资源生成保守身份目录、ASTC4×4增量和抽样质量报告 |
| 四分之一视觉纹理候选 | `quarter_texture_overlay.py`、`quarter_texture_worker.gd` | 从绑定源生成独立 ASTC8×8 视觉纹理增量并核验尺寸、来源及采样质量 |
| 四分之一纹理合并门禁 | `merge_quarter_texture.py` | 复算候选闭集并核验逐项身份、质量和固定主包 SHA 后流式合并 |
| 四分之一纹理精修 | `refine_quarter_texture.py`、`refine_quarter_texture.gd`、`refine_quarter_astc.cpp` | 对先前拒绝的视觉资源尝试透明加权 ASTC，保留质量门并绑定独立父包 |
| 精修纹理合并门禁 | `merge_refined_quarter.py` | 复算精修候选和质量尝试，验证源/父包身份与替换闭集后输出独立主包 |
| 纹理增量组合 | `combine_restored_texture.py` | 校验来源与逐项闭集，流式合并基础纹理覆盖和恢复增量 |
| 字体缓存候选 | `strip_font_cache.py`、`strip_font_cache.gd` | 严格绑定新版源包和主包，离线清理三张简中字库预生成字号缓存并验证原始字体、参数和字形 |
| 通用字体缓存候选 | `strip_common_font_cache.py`、`strip_common_font_cache.gd` | 在既有简中结果不变的前提下，绑定当前主包并验证六张通用字体的拉丁字形和固定输出身份 |
| Mono 子集独立试验 | `subset_mono_font.py`、`subset_mono_font_worker.py`、`subset_mono_font.gd`、`subset_mono_uid_fixture.gd` | 固定原始字库及工具身份，仅委托字宽相同的CJK字形并验证完整主包UID、覆盖与字宽 |
| Mono 子集合并门禁 | `merge_mono_subset_trial.py`、`mono_subset_device_merge.py` | 固定单项字体候选，分别在host与隔离设备试验目录验证来源、闭集与主包结果 |
| 地图画布独立试验 | `map_canvas_trial.py`、`map_canvas_fixture.gd` | 固定9caf父包，仅缩小手写地图的物理画布并保留逻辑坐标，输出独立资源包和几何验证 |
| 字体图集候选 | `font_atlas_trial.py`、`font_atlas_trial.gd`、`font_atlas_uid_fixture.gd`、`font_atlas_corpus.py`、`font_atlas_metrics_fixture.gd`、`merge_font_atlas_trial.py` | 固定9caf、衡量中英字宽和图集，生成与验证单一Medium字体的40/14实验覆盖 |
| 字体预算合并门禁 | `merge_font_budget_trial.py` | 固定099父包及已审字体增量，验证四项闭集并流式合成私有候选 |
| 字体预算独立试验 | `font_budget_trial.py`、`font_budget_trial.gd` | 固定源和父包，保全字库并降低 SC 字体距离场范围、共享合成粗体，生成私有覆盖与覆盖率证据 |
| 简中 fallback 独立试验 | `font_fallback_trial.py`、`font_fallback_trial.gd`、`font_fallback_alias_fixture.gd`、`merge_font_fallback_trial.py` | 验证字体引用与中文覆盖，按严格身份生成和合并仅供中文比较的私有候选，用法见 README |
| 默认主题字体试验验证 | `test_bundled_theme_font.gd` | 用真实引擎验证 opt-in、中文码点、字体对象复用与自定义主题覆盖 |
| SC 字体缺字验证 | `test_sc_fallback_coverage.gd` | 仅在私有 host 进程测试三种 SC 字体的本地化覆盖和继承 fallback |
| 战斗遮罩字体修复试验 | `build_warmup_cover_trial.py`、`test_warmup_cover.gd` | 固定身份替换单个兼容脚本，并对照系统字体读取和无字回退，用法见 README |
| Windows 纹理转换 | `windows_texture_overlay.py`、`windows_texture_worker.gd` | 校验导入映射，将桌面 BC 纹理转换为 ASTC 或保护性 RGBA 并生成覆盖报告 |
| low_texture_worker.gd | `low_texture_worker.gd` | 使用官方 Godot CPU 图像编解码器转换纹理 |
| merge_texture_pck.py | `merge_texture_pck.py` | 校验报告与纹理闭集，流式生成独立低清主包及身份清单，不改原包 |
| limit_texture_size.py | `limit_texture_size.py` | 按全局与路径规则限制移动端纹理重导入尺寸 |
| patch_project.py | `patch_project.py` | 配置恢复工程的 ASTC/ETC2 压缩目标及定制编辑器参数 |
| set_mipmaps.py | `set_mipmaps.py` | 在重导入前统一控制移动端纹理 mipmap 链 |
| strip_non_astc.py | `strip_non_astc.py` | 在重导入后移除 Mali 无法使用的 BPTC/S3TC 资源 |
| strip_sources.py | `strip_sources.py` | 在重打包前移除已被导入资源替代的冗余源图片 |
| extract.sh | `extract.sh` | 为资源压缩与覆盖补丁准备 PCK 恢复工作树 |
| reimport.sh | `reimport.sh` | 按修改后的纹理策略清理缓存并重新导入资源 |
| repack.sh | `repack.sh` | 为可完整重建的 Godot 项目提供直接重打包入口 |
| verify_astc_8x8.sh | `verify_astc_8x8.sh` | 只读检查移动纹理重导入是否生成预期 ASTC 8x8 格式 |
| README.md | `README.md` | 纹理压缩流水线与使用说明 |
| bin-README.md | `bin-README.md` | 外部 GDRE/Godot 工具准备说明 |
| .gitignore | `.gitignore` | 外部工具、工作树与资源产物忽略规则 |
| patches | `patches/` | 按游戏组织的覆盖内容和构建方案 |
