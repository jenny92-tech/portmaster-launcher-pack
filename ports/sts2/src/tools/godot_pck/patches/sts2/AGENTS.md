# STS2 资源处理方案

build.sh 将 STS2 原包恢复为工作工程，应用纹理策略后重导入；apply.sh 把 overlay 内的 ARM64 扩展映射和 Sentry 替代脚本加入工程。最终覆盖仍以原包保留无法在宿主重建的资源，strip_worldenv.py 则是独立的无 3D 处理步骤。

## 约束

- 最终覆盖以原始游戏包为基底，保留宿主编辑器无法重建的 Spine/FMOD 资源。
- 恢复目录与中间覆盖目录可被构建流程清理，执行前核验输入和工作范围。
- 正式启动入口在上级移植 love 目录；scripts 仅保留设备实验和观测工具。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| apply.sh | `apply.sh` | 复制扩展映射与 Sentry 替代资源 |
| build.sh | `build.sh` | 原包恢复 → 策略调整 → 重导入 → 增量覆盖 |
| strip_worldenv.py | `strip_worldenv.py` | 从恢复场景移除无 3D 构建不支持的环境节点 |
| README.md | `README.md` | 游戏专属补丁背景和刷新条件 |
| overlay | `overlay/` | 遵循原 res:// 路径的静态打包输入 |
| scripts | `scripts/` | 独立 SDL 启动及内存观察，不接正式 UI |
