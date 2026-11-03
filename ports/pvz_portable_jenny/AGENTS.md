# PvZ Portable 维护版

此端口消费独立 PvZ-Portable 工程的原生运行时，维护掌机入口、gptk 和发行元数据。构建时可通过 PVZ_PORTABLE_RUNTIME 提供引擎及依赖；玩家游戏资源和状态仍在既有数据布局中，源码包不提供这些内容。

## 约束

- 不打包 main.pak、properties、userdata、注册信息、缓存和玩家设置。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 清单 | `manifest.json` | 端口身份、安装项与补资源说明 |
| 说明 | `README.md` | 引擎来源、构建变量和玩家资源要求 |
| 授权 | `LICENSE` | 启动器、引擎和游戏资源边界 |
| 源码 | `src/` | Bash 设备入口、年度版映射及固定清单构建 |
| 忽略规则 | `.gitignore` | 生成的 dist |
