# STS2 掌机移植

> 为 Slay the Spire 2 提供 ARM Linux 掌机启动器与兼容层。

## 地位

ports 下需要独立 C# 构建与着色器打包流程的游戏端口。

## 逻辑

love 声明设置 UI 和两阶段启动模板；src 实现运行时补丁并提供资源转换、组装和诊断；manifest 将端口接入共享分发工具。

## 约束

- 玩家须自行提供合法游戏内容；遵守游戏和外部运行时的既有分发边界。
- 正式启动的 LÖVE/游戏显示环境保持隔离，设备实验脚本不替代正式入口。
- 遵循仓库根 FRACTAL-DOCS.md 导航约定与 AGENTS.md 版本纪律，文档初始化不重建二进制。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| .gitattributes | `.gitattributes` | 二进制和媒体文件的 Git LFS 属性 |
| .gitignore | `.gitignore` | 游戏引用、外部运行时和构建产物忽略规则 |
| LICENSE | `LICENSE` | 本端口许可证文本 |
| README.md | `README.md` | 端口定位、构建流程和外部依赖说明 |
| manifest.json | `manifest.json` | 共享工具消费的端口元数据与启动脚本配置 |
| screenshot.png | `screenshot.png` | PortMaster 展示截图 |
| love | `love/` | 共享 LÖVE 设置声明及 STS2 两阶段启动模板 |
| src | `src/` | 运行时兼容实现、构建输入与移植工具 |

