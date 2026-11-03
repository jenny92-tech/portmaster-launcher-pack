# 桌面 CLI 构建工作流

`portkit-download.yml` 使用手动触发入口构建 Windows x64 和 macOS 通用包，并执行对应检查。它交付下载工具，不打包掌机运行时或游戏资源。

## 约束

- 保持 Windows x64、macOS Intel/Apple Silicon 的目标与归档名称对应。
- 使用只读仓库权限和两天产物保留期；Release 发布另行处理。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 下载工具 CI | `portkit-download.yml` | 平台构建、测试、macOS 合并及短期产物上传 |
