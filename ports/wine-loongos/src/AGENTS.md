# 共享 Je-Wine 源码

入口先以 bootstrap 加载随包解释器，再由 launcher 发现 bottle；wine_catalog 按 device/environment 继承解析 API 组件，wine_session 管理准备后的游戏会话。安装器只原子切换公共 runtime，游戏 namespace、prefix 和存档由各会话隔离，设备无需源码仓库。

## 约束

- 不把机型名、GPU/音频路径、共享 DLL 放入游戏适配。
- 继承只允许本类别目录；字典合并、列表替换，不猜测未支持固件。
- 运行器 ZIP、运行组件包、游戏适配 ZIP 和电脑准备工具分别生成。
- 玩家提供完整游戏；准备过程验证输入和输出版本，保留原始文件。
- 所有游戏使用 namespace、独立 prefix 和正常关窗，不超时强杀图形会话。
- 更新只切换 runtime 链接；活动会话持有环境共享锁，安装器需独占锁。
- 菜单与游戏独占物理手柄，不停止固件服务，不提供 winecfg 入口。
- 下表配置目录只存维护定义和工具输入；玩家游戏、prefix、存档及安装缓存按 wine_layout.py 的状态布局保存。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| Windows 入口 | `launcher.sh` | 从 .winecellar 定位执行环境和游戏库 |
| 私有启动引导 | `bootstrap.sh` | 校验自带解释器并在普通 Shell 下引导 |
| 游戏列表 | `launcher.py` | bottle 发现、手柄菜单和会话交接 |
| 游戏库视觉 | `wine_ui.py` | 原生 SDL 封面卡片、受限 PNG 读取、文字/纹理缓存和全屏等待画面 |
| 目录布局 | `wine_layout.py` | Windows 库、.winecellar 状态/组件路径和 Ports 桥接的唯一约定 |
| 游戏描述 | `wine_bottle.py` | 社区 bottle 元数据、受控 runner/deps/env 与显式启动声明校验 |
| 分层依赖 | `wine_catalog.py` | 设备/环境继承与 API 组件解析 |
| 共享环境安装 | `runtime_install.py` | 离线/HTTPS 身份校验、映像安装和 runtime 切换 |
| 离线运行包 | `wine_package.py` | 离线 ZIP 清单生成、有限目录识别和导入 |
| 映像身份 | `runtime_mount.py` | 验证 loop 映像的数据目录归属 |
| 游戏准备 | `wine_game.py` | 玩家文件和版本校验、隔离入口准备、可选资源修改 |
| 输入会话 | `wine_input.py` | 映射快照、输入独占及退出/清理 |
| 隔离游戏会话 | `wine_session.py` | 选择图形组件、独立 prefix 与正常关窗 |
| 公共显示补丁 | `runtime-patches/` | Wine 原生全屏、启动背景与 WSI 帧回调的固定源码 |
| 正常关窗源码 | `wine_close.c` | 向当前私有 Wine 桌面发送 WM_CLOSE |
| 全屏助手源码 | `wine_borderless.c` | 指定窗口的原生最大化、去边框和客户区调整 |
| 设备定义 | `devices/` | 基础/家族继承、library_directory 和具体机型差异 |
| 环境定义 | `environments/` | 公共环境基础、GPU 家族实现与固件路径差异 |
| 组件目录 | `components/` | build-runtime.py 生成的公共组件来源与固定校验目录 |
| 游戏适配 | `adapters/` | 各游戏的 bottle.json、adapter.json、input.gptk，只声明游戏自身要求 |
| 电脑准备工具 | `preprocessors/` | 共用工具合同、来源授权和隔离容器 Dockerfile |
| 通用键鼠 | `desktop.gptk` | 无专用映射时的键鼠输入 |
| 自定义游戏样例 | `wine-game.example.json` | 显式 EXE、图形 API 和游戏选项 |
| Bottle 样例 | `bottle.example.json` | 社区元数据与 wine_runner 启动声明的组合样例 |
| 补资源说明 | `games-README.txt` | 玩家完整游戏目录的放置说明 |
| 构建与分发 | `scripts/` | 按运行器/组件/游戏/准备工具输出独立包 |
