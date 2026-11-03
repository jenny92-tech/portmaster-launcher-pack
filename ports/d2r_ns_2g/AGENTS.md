# D2R NS 2G 适配入口

与 d2r_ns 并存，将已有的经典 2G 安装接入 Pack；仅导入路径，游戏和 runtime 仍由 D2R Linux 准备。

## 约束

- 保留来源安装的 profile 路径；不得改用其他 D2R 端口的档案。
- 2G 是预设身份，不代表已经完成 2 GB 硬件验收；只接收已准备的匹配 Release runtime。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 清单 | `manifest.json` | 独立 Je- 入口和外部准备边界 |
| 说明 | `README.md` | 三步准备、打包安装与硬件验收范围 |
| 授权 | `LICENSE` | Pack 集成与 D2R MIT 运行逻辑边界 |
| 封面 | `screenshot.png` | 复用 D2R NS 已有品牌封面 |
| 源码 | `src/` | 2G 执行逻辑、路径桥接与打包 |
| 回归 | `tests/` | 非执行导入与只读预检验证 |
| 忽略规则 | `.gitignore` | 生成目录与临时组装目录 |
