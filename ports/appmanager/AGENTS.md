# APP Manager 端口

ports/ 下使用专用 LOVE-lite runtime 与 Rust 服务的应用端口；其核心文件操作和设备模型位于 crates/。manifest 定义发行路径与 TrimUI 包装；src/ 启动 bundled runtime，love/ 通过原生桥接呈现库存和操作，退出后交接选定游戏脚本。

## 约束

- Lua 是表现与交互层；环境解析、安装和文件操作由 Rust 服务负责。
- portable/ 保存随包依赖及许可资源，二进制由对应构建流程维护，不手工修改。
- dist/ 为构建产物，不维护分形源码文档；revision 是构建身份而非格式版本。
- Port 同名封面及 screenshot.png 均放入 jenny92-appmanager 数据目录；服务从 app_root 读取同名封面并同步到配置的前端图片目录。manifest 的 image 指定源图片，attr.image 指定包内预览路径；根安装项仅含启动脚本和应用目录。
- TrimUI APP 入口与 PortMaster 封面是两套独立资源。`trimui-app/icon.png` 保留系统匹配的原始 300×300 画布、圆角方形图案及留白，不用透明抠图重新铺满或缩放；PortMaster 封面与 APP 内部品牌图沿用各自资源，不把入口样式互相覆盖。APP Manager 不额外叠加作者外框或右下角标。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | 应用身份、入口、便携目录和 TrimUI/PortMaster 包装配置 |
| 使用说明 | `README.md` | 安装、能力边界与应用使用文档 |
| 冒烟检查 | `SMOKE_TEST.md` | 设备环境和交互验收步骤 |
| 授权 | `LICENSE` | 端口授权声明 |
| Runtime 构建身份 | `love-lite-revision.txt` | 捆绑 LOVE-lite 的源码与二进制身份记录 |
| 启动器封面 | `screenshot.png` | 640×640 透明紫猫、齿轮与扳手，无外框和角标 |
| 小尺寸预览 | `screenshot_small.png` | 256×256 同款透明图片，无外框和角标 |
| Lua 界面 | `love/` | 统一页面骨架、业务页面、模型、任务和原生桥接，见子目录 AGENTS.md |
| 轻量入口 | `src/` | runtime 引导和游戏交接，见子目录 AGENTS.md |
| 捆绑依赖 | `portable/` | LOVE-lite、输入助手、字体、控制器数据库、证书包与许可；`share/appmanager.png` 是 APP 内部及 PortMaster 封面的透明品牌图 |
| TrimUI 图标 | `trimui-app/` | 独立的原始 300×300 圆角方形图标，保留系统匹配的视觉尺寸与留白 |
