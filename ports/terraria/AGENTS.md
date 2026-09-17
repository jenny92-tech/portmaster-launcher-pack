# 泰拉瑞亚端口

> 以玩家 Android APK 提供游戏资源，并统一启动语言、画面与按键设置。

## 地位

ports/ 下复用 LÖVE 启动器和 Bogodroid UnityLoader 的游戏端口。

## 逻辑

patch/ 负责首次 APK 解包；love/ 提供设置和资源门禁，将 TER_* 配置应用到游戏后启动；tests/ 固定语言与共享启动接口契约。

## 约束

- 不携带游戏内容，玩家需自行提供合法 APK；失败时保留 APK 供重试。
- gamedata 路径和语言参数在界面、Shell、patcher 和测试之间保持一致。
- dist/ 是生成发行目录，不直接修改或初始化源码文档。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | 游戏身份、运行依赖和发行路径 |
| 授权 | `LICENSE` | 端口授权声明 |
| 预览图 | `screenshot.png` | 发行包游戏截图 |
| 启动界面 | `love/` | 语言/图形/输入选项及启动流程，见子目录 AGENTS.md |
| 首次资源准备 | `patch/` | APK 解包和核心校验，见子目录 AGENTS.md |
| 契约测试 | `tests/` | 语言与共享启动接口回归，见子目录 AGENTS.md |
