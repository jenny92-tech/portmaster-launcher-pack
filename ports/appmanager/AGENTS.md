# APP Manager 端口

此目录将 LOVE-lite、Rust 管理服务和 Lua 页面组装为 PortMaster Port 或 TrimUI App。manifest 决定两种安装布局；`src/launcher.sh` 启动 runtime，`love/` 通过原生服务执行管理事务，并在退出后交接选定游戏。业务实现位于 `crates/appmanager-*`，不在发行目录中复制。

## 约束

- Lua 是表现与交互层；环境解析、安装和文件操作由 Rust 服务负责。
- portable/ 保存随包依赖及许可资源，二进制由对应构建流程维护，不手工修改。
- Port 同名封面及 screenshot.png 均放入 jenny92-appmanager 数据目录；服务从 app_root 读取同名封面并同步到配置的前端图片目录。manifest 的 image 指定源图片，attr.image 指定包内预览路径；根安装项仅含启动脚本和应用目录。
- TrimUI APP 入口与 PortMaster 封面是两套独立资源。`trimui-app/icon.png` 保留系统匹配的原始 300×300 画布、圆角方形图案及留白，不用透明抠图重新铺满或缩放；PortMaster 封面与 APP 内部品牌图沿用各自资源，不把入口样式互相覆盖。APP Manager 不额外叠加作者外框或右下角标。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | Port/TrimUI 安装项、入口和图片来源 |
| 使用说明 | `README.md` | 安装、能力边界与应用使用文档 |
| 冒烟检查 | `SMOKE_TEST.md` | 设备环境和交互验收步骤 |
| 授权 | `LICENSE` | 端口授权声明 |
| Runtime 构建身份 | `love-lite-revision.txt` | 捆绑 LOVE-lite 的源码与二进制身份记录 |
| 启动器封面 | `screenshot.png` | 640×640 透明紫猫、齿轮与扳手，无外框和角标 |
| 小尺寸预览 | `screenshot_small.png` | 256×256 同款透明图片，无外框和角标 |
| Lua 界面 | `love/` | 页面、任务状态及原生桥接适配 |
| 轻量入口 | `src/` | runtime 引导、日志轮转与退出交接 |
| 捆绑依赖 | `portable/` | runtime、输入工具、字体、数据库、证书及许可；品牌图位于 share/appmanager.png |
| TrimUI 图标 | `trimui-app/` | 独立的原始 300×300 圆角方形图标，保留系统匹配的视觉尺寸与留白 |
