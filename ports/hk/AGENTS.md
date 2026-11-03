# 空洞骑士端口

空洞骑士端口把 LÖVE 设置连接到 Rudroid/UnityLoader。Lua 生成 HKL_* 参数，Shell 将其同步到游戏 TOML、GraphicsSettings 与启动器拥有的 PlayerPrefs 视频键；manifest 和共享打包器负责发行布局。

## 约束

- 保存玩家非启动器拥有的偏好；视频引导修复不能覆盖语言或音频设置。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | 运行依赖、安装目标与入口 |
| 使用说明 | `README.md` | 端口部署与运行说明 |
| 授权 | `LICENSE` | 端口授权声明 |
| 启动器封面 | `screenshot.png` | 包预览与启动封面的原图 |
| 启动界面 | `love/` | HKL_* 字段、视频引导修复及 Unity 交接 |
