# 游戏侧渲染准备

兼容 DLL 在场景树可用后挂载 render_compat.tscn，由 render_compat.gd 协调实际后端、材质适配和资源缓存。启动预载与当前房间预热各自报告完成/失败并回收自有节点；此层不接管引擎、平台或存档。

## 约束

- 只按 shaders/render-compat.json 的精确资源路径及代码身份替换，保留古卡遮罩和 MOD 材质。
- 原生 Spine 预览必须重新实例化；不得 Duplicate 活体角色、触发其状态机或删除 Spine 网格子节点。
- 场景退出、预热失败和超时必须解除遮罩并释放自有节点；共享资源只解除引用，不显式 free。
- 预热特效由桥交给当前房间的 CombatVfxContainer；容器无效时回收未挂载特效。
- GPU 专项规则检查实际 rendering method、driver、adapter 和 OS，不能用型号或请求参数猜测。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 启动场景 | `render_compat.tscn` | 供托管桥挂载的 Node 场景 |
| 协调入口 | `render_compat.gd` | 实际后端策略、共享浮层及缓存协调 |
| 中文默认字体试验 | `bundled_font_trial.gd` | 显式开关下替换内置默认字体及其变体，保持游戏自定义主题覆盖 |
| 启动特效预载 | `startup_effect_preload.gd` | 清单内 PackedScene 的离屏预载与有界终态，不实例化游戏根节点 |
| 材质适配 | `shader_compat.gd` | 精确识别、实例材质副本与流畅档粒子规则 |
| 战斗预热 | `combat_warmup.gd` | 当前房间独立 Spine/视觉预热及遮罩生命周期，标题只复用已有字体 |
| 轻量特效 | `simple_effect.gd` | 无纹理短闪光及场景约定的根节点释放 |
