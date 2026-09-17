# 龙沉异世录包组装

> 提供完整验证基线包与玩家资源驱动的最小包组装流程。

## 地位

龙沉异世录的开发侧发行暂存脚本，消费独立 Bogodroid 构建产物。

## 逻辑

两条流程都校验 ARM64 runtime、插件与支持文件后调用 `_kit/dist_port.sh`；完整包复制 Android payload，最小包只复制无法从 Windows 资源获取的核心文件。

## 约束

- 完整 Android 基线是硬件稳定性验证基准，最小包资源迁移是独立实验。
- Python 需提供 tomllib；runtime 和插件必须来自匹配构建。
- 组装会改写 dist/ 和校验和，不在只读分析或文档初始化时运行。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 完整基线 | `stage-full-package.sh` | 暂存完整 Android payload、Steam companion 与 runtime |
| 最小包 | `stage-minimal-package.sh` | 暂存最小 ARM64 核心并要求玩家补充 Windows GameData |
