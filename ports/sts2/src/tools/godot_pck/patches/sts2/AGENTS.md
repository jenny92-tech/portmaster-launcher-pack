# STS2 资源处理方案

> 将通用纹理处理工具组合为掌机版游戏资源覆盖流程。

## 地位

godot_pck 中面向 STS2 的游戏专属编排和覆盖内容。

## 逻辑

build.sh 恢复原包、修改纹理策略、重导入并组装覆盖包；apply.sh 加入扩展映射和 Sentry 替代；strip_worldenv.py 为无 3D 实验提供独立处理。

## 约束

- 最终覆盖以原始游戏包为基底，保留宿主编辑器无法重建的 Spine/FMOD 资源。
- 恢复目录与中间覆盖目录可被构建流程清理，执行前核验输入和工作范围。
- 正式启动入口在上级移植 love 目录；scripts 仅保留设备实验和观测工具。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| apply.sh | `apply.sh` | 将 STS2 ARM64 扩展替代文件应用到恢复工程 |
| build.sh | `build.sh` | 编排保留原始扩展资源的 STS2 Mali 纹理覆盖构建 |
| strip_worldenv.py | `strip_worldenv.py` | 为无 3D Godot 构建去除不可用的环境节点 |
| README.md | `README.md` | 游戏专属补丁背景和刷新条件 |
| overlay | `overlay/` | 按原 res:// 结构保存的静态兼容覆盖 |
| scripts | `scripts/` | SDL2 设备实验启动器与内存采样工具 |

