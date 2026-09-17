# 龙沉异世录端口

> 提供实验性 Bogodroid 启动器、玩家资源准备与发行基线流程。

## 地位

ports/ 下的 Unity IL2CPP 移植实验，连接外部 Bogodroid 构建结果和玩家 Windows 游戏资源。

## 逻辑

src/ 组装完整 Android 基线或最小 runtime 包；patch/ 转换玩家可复用资源布局；love/ 检查资源、设置显示和按键后启动 Unity。

## 约束

- 玩家 GameData 保持只读，ARM64 核心与其元数据必须来自匹配构建。
- 完整基线与最小资源迁移路径分开验证，不能未经设备测试宣称稳定。
- dist/ 及 payload 校验和属于组装产物，文档初始化不重建它们。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | 实验端口身份、依赖、目标设备和发行配置 |
| Unity 配置 | `config.toml.template` | 默认 Bogodroid 游戏与运行配置模板 |
| 使用说明 | `README.md` | 当前移植状态、资源准备与使用说明 |
| 授权 | `LICENSE` | 端口授权声明 |
| 预览图 | `screenshot.png` | 发行包游戏截图 |
| 玩家资源说明 | `GameData/` | 玩家 Windows 游戏放置说明，不含游戏源内容 |
| 启动界面 | `love/` | 设置与资源门禁，见子目录 AGENTS.md |
| 资源转换 | `patch/` | 玩家资源到运行布局的准备脚本，见子目录 AGENTS.md |
| 开发流程 | `src/` | 完整基线和最小包组装，见子目录 AGENTS.md |
