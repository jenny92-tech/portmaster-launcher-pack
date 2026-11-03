# D2R NS 打包工具

共享 dist 调度调用 `dist-port.sh`，从 `D2R_NS_2G_ENTRY` 的字面路径或 `D2R_NS_2G_PATHS` 的已有 JSON 生成 install-paths.json。两种导入均不运行来源 SH、不探测清单中的安装目标；无输入时只生成待配置的启动器骨架。

## 约束

- `D2R_NS_2G_ENTRY` 与 `D2R_NS_2G_PATHS` 互斥；输入按数据校验，保持原 profile 路径。
- `.scratch/d2r-ns/stage` 以 mkdir 原子占用并记录 dev:inode；退出时只清理同身份目录，发布后继任构建占用的同名槽不受影响。
- 发布负载仅含启动代码、路径清单、封面和许可，不收集安装目标中的文件。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 发行构建 | `dist-port.sh` | 占用固定 stage，组装代码/清单并发布端口 dist |
| 路径导入 | `import-entry.py` | extract 解析入口；--paths 复用 launch.load_paths 校验 |
