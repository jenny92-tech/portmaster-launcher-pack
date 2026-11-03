# 龙沉异世录包组装

两个 stage 脚本在调用共享 dist 之前检查 ARM64 runtime、插件和支持文件。stage-full-package.sh 选择完整 Android payload；stage-minimal-package.sh 只收集 Windows 资源无法提供的核心，两者的输入集合与验证目的不同。

## 约束

- 完整包用于验证 Android 基线；最小包另需验证 Windows 资源迁移，不能用前者结果替代后者。
- Python 需提供 tomllib；runtime 和插件必须来自匹配构建。
- 组装会重新生成 dist/ 和校验和，原始输入不得放入输出目录。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 完整基线 | `stage-full-package.sh` | 完整 Android 基线、Steam companion 和 runtime |
| 最小包 | `stage-minimal-package.sh` | 最小核心/runtime 与玩家 GameData 准备层 |
