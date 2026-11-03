# 游戏侧渲染准备

PCK 内的 Godot 原生适配层，由兼容 DLL 在场景树可用后创建。实际渲染器检测、材质隔离、当前战斗预热与缓存保留均在此执行，不改引擎、平台或存档。

## 约束

- 只按 shaders/render-compat.json 的精确资源路径及代码身份替换，保留古卡遮罩和 MOD 材质。
- 原生 Spine 预览必须重新实例化；不得 Duplicate 活体角色、触发其状态机或删除 Spine 网格子节点。
- 场景退出、预热失败和超时必须解除遮罩并释放自有节点；共享资源只解除引用，不显式 free。
- 预热特效由桥交给当前房间的 CombatVfxContainer；容器无效时回收未挂载特效。
- GPU 专项规则检查实际 rendering method、driver、adapter 和 OS，不能用型号或请求参数猜测。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 启动场景 | `render_compat.tscn` | 原生 Node 入口 |
| 协调入口 | `render_compat.gd` | 实际后端策略、共享性能浮层、节点批处理、资源缓存接口 |
| 中文默认字体试验 | `bundled_font_trial.gd` | 显式开关下替换内置默认字体及其变体，保持游戏自定义主题覆盖 |
| 启动特效预载 | `startup_effect_preload.gd` | 按生成清单持有轻量 PackedScene，离屏绘制并报告有界完成状态，不实例化游戏根节点 |
| 材质适配 | `shader_compat.gd` | 路径/生成代码识别、每实例材质副本和流畅档命中/减益粒子的定点湍流、数量与模拟频率调整 |
| 战斗预热 | `combat_warmup.gd` | 当前房间的独立 Spine 与视觉预热、阶段计时及仅复用已有字体的遮罩标题 |
| 轻量特效 | `simple_effect.gd` | Smooth 包中短暂显示无纹理闪光；按场景释放特效根或保留原定时清理 |
