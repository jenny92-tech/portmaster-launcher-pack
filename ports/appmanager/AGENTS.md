# APP Manager 端口

> 提供独立的掌机应用、PortMaster 与 Runtime 管理工具。

## 地位

ports/ 下使用专用 LOVE-lite runtime 与 Rust 服务的应用端口；其核心文件操作和设备模型位于 crates/。

## 逻辑

manifest 定义发行路径与 TrimUI 包装；src/ 启动 bundled runtime，love/ 通过原生桥接呈现库存和操作，退出后交接选定游戏脚本。

## 约束

- Lua 是表现与交互层；环境解析、安装和文件操作由 Rust 服务负责。
- portable/ 是随包依赖及许可资源，不手改二进制或为文档工作重建 runtime。
- dist/ 为构建产物，不维护分形源码文档；revision 是构建身份而非格式版本。
- Port 同名封面及 screenshot.png 均放入 jenny92-appmanager 数据目录；服务从 app_root 读取同名封面并同步到配置的前端图片目录。manifest 的 image 指定源图片，attr.image 指定包内预览路径；根安装项仅含启动脚本和应用目录。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | 应用身份、入口、便携目录和 TrimUI/PortMaster 包装配置 |
| 使用说明 | `README.md` | 安装、能力边界与应用使用文档 |
| 冒烟检查 | `SMOKE_TEST.md` | 设备环境和交互验收步骤 |
| 授权 | `LICENSE` | 端口授权声明 |
| Runtime 构建身份 | `love-lite-revision.txt` | 捆绑 LOVE-lite 的源码与二进制身份记录 |
| 界面预览 | `screenshot.png` | 包预览截图 |
| 小尺寸预览 | `screenshot_small.png` | 较小尺寸的应用预览图 |
| Lua 界面 | `love/` | 页面、模型、任务和原生桥接，见子目录 AGENTS.md |
| 轻量入口 | `src/` | runtime 引导和游戏交接，见子目录 AGENTS.md |
| 捆绑依赖 | `portable/` | LOVE-lite、输入助手、字体、控制器数据库、证书包与许可 |
| TrimUI 图标 | `trimui-app/` | 原生应用包装使用的图标资源 |
