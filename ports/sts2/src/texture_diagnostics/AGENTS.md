# STS2 独立纹理诊断

独立 PCK 构建器将本目录放入 `res://port_diagnostics/`，兼容层只在显式启用后挂载。runner 分帧观察已存在节点、纹理和缓存，并汇总 viewport/Performance 数据；它既不属于主包覆盖，也不触发游戏资源加载。

## 约束

- 只通过静态类型绑定调用经对抗验证的原生控件方法及 Spine 只读接口；不调用脚本getter或读取图像像素、托管堆或其他进程，不加载游戏资源。
- 限制遍历数量、日志与扫描次数并分帧执行；不修改游戏节点、资源或渲染设置。额外的鼠标输入仅在三重开关及私有隔离根验证通过时启用。
- 路径只允许 `res://port_diagnostics/`，独立挂载不得覆盖原有资源；结果不是全部纹理、RSS 或 GPU 精确分配。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 纹理采样器 | `texture_diagnostic.gd` | 去重纹理/viewport 元数据；缓存查询后解除引用 |
| 资源聚合采样 | `resource_stats.gd` | 现成 Performance 与 FMOD 缓存聚合，不驱动更新 |
| 诊断入口 | `texture_diagnostic_runner.gd` | 有限次数扫描、结果输出及自动退出 |
| 诊断场景 | `texture_diagnostic.tscn` | 独立 PCK 内的 Node 入口 |
| UI观察器 | `ui_diagnostic.gd`、`ui_diagnostic.tscn` | 实际 user:// 位于无符号链接隔离根时观察原生控件；控制另需开关与 0700 根 |
| 指标说明 | `README.md` | 开关、指标口径及不可观测范围 |
