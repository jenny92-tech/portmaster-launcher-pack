# 共享 Je-Wine 源码

运行器维护源码；src/scripts 生成发行材料，设备不依赖仓库。launcher 识别 devices 并选择 environments；游戏只声明 API 和自己的准备规则。 环境将 API 映射到 components 中的共享实现。安装器原子切换运行库，session 隔离每游戏配置和存档。

## 约束

- 不把机型名、GPU/音频路径、共享 DLL 放入游戏适配。
- 继承只允许本类别目录；字典合并、列表替换，不猜测未支持固件。
- 运行器 ZIP、运行组件包、游戏适配 ZIP 和电脑准备工具分别生成。
- 玩家提供完整游戏；准备过程验证输入和输出版本，保留原始文件。
- 所有游戏使用 namespace、独立 prefix 和正常关窗，不超时强杀图形会话。
- 更新只切换 runtime 链接；活动会话持有环境共享锁，安装器需独占锁。
- 菜单与游戏独占物理手柄，不停止固件服务，不提供 winecfg 入口。
- 默认只做本地验证；设备连接、部署或启动游戏须属于明确的设备验证任务。
- 下表的配置与工具数据目录由本清单统一导航，不存放玩家游戏、存档、测试缓存或设备凭据。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| Windows 入口 | `launcher.sh` | 从 .winecellar 加载私有执行环境，定位 Windows 库与状态目录 |
| 私有启动引导 | `bootstrap.sh` | 以普通 Shell 校验并加载自带解释器，不依赖系统 Python |
| 游戏列表 | `launcher.py` | bottle 游戏发现、手柄导航/说明弹层、生命周期与会话交接 |
| 游戏库视觉 | `wine_ui.py` | 原生 SDL 封面卡片、受限 PNG 读取、文字/纹理缓存和全屏等待画面 |
| 目录布局 | `wine_layout.py` | Windows 库、.winecellar 状态/组件路径和 Ports 桥接的唯一约定 |
| 游戏描述 | `wine_bottle.py` | 社区 bottle 元数据、受控 runner/deps/env 与显式启动声明校验 |
| 分层依赖 | `wine_catalog.py` | 配置继承、机型识别和公共组件依赖解析 |
| 共享环境安装 | `runtime_install.py` | 自动导入标准离线 ZIP、离线/HTTPS 校验安装、私有映像和原子运行库切换 |
| 离线运行包 | `wine_package.py` | 生成 ZIP 身份清单，在有限目录按内容识别，以内置组件目录校验并导入缓存 |
| 映像身份 | `runtime_mount.py` | 核对 loop 映像属于选定数据目录 |
| 游戏准备 | `wine_game.py` | 玩家文件和版本校验、隔离入口准备、可选资源修改 |
| 输入会话 | `wine_input.py` | PortMaster 输入优先/随包回退、共享映射快照、手柄独占、退出组合键和清理 |
| 隔离游戏会话 | `wine_session.py` | 环境选图形实现、独立 prefix、只读资源覆盖与正常退出 |
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
| 构建与分发 | `scripts/` | 独立运行器、组件、游戏和准备工具产物 |
