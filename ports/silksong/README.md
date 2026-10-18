# 空洞骑士：丝之歌端口

本端口维护启动器、设置界面和启动模板；Rudroid/UnityLoader 运行时、玩家资源和压缩后的 bundle 单独部署。

## 菜单入口

生成后的菜单脚本为 `K_空洞骑士_丝之歌[中].sh`。启动模板兼容 `/userdata/silksong`、`/mnt/UDISK/silksong` 和 PortMaster 游戏目录；优先读取独立端口包的 `love_ui`，否则使用游戏目录内的界面。

## 设置布局

| 页面 | 设置 | 新状态默认值 |
| --- | --- | --- |
| 常用 | 渲染分辨率 | 跟随游戏预设 |
| 常用 | 内存模式 | 均衡 |
| 高级 | 显示分辨率 | 自动跟随设备 |
| 高级 | 图形后端 | 游戏默认 OpenGL ES；可用时选实验 Vulkan |
| 高级 | 画面模式 | 低画 / 稳定 |
| 高级 | 帧率上限 | 跟随游戏预设 |
| 高级 | 装饰物 | 75% |
| 高级 | A/B、X/Y 交换 | 关 |

已有合法选择保留；“跟随游戏预设”不会清除 TOML 中的精确渲染尺寸或强制设置帧率。显式渲染比例可选 100% / 75% / 50%；显式帧率可选 90 / 60 / 45 / 30 / 25。

低内存 / 均衡 / 高内存分别写入 `[runtime].memory_mode` 的 `low_memory` / `balanced` / `performance`。这是 Rudroid 的按需资源流缓冲及受支持的音频预加载默认策略，不是整个 Unity 游戏的内存上限，也不承诺切档后帧率必然提升。显式资源缓冲和 `disable_audio_preloader` 配置优先保留。内存档不隐式修改帧率、画质或渲染线程。

## 画面模式与后端

Vulkan 在高级页选择，支持同一套 100% / 75% / 50% 渲染，缩放使用线性滤波。
不支持的后端不能选择，已存不可用值在显示前改为可用默认值；启动不暗中
换后端。不适用项显示“禁用”，滤波由程序处理。私有 WSI 随同 kit 安装，不替换系统驱动。
Vulkan 可能降低 CPU 开销，也可能增加 GPU 内存，不保证更高帧率。

效果随低画 / 原彩统一切换，不单独提供底层开关。

| 效果 | 低画默认 | 原彩默认 |
| --- | --- | --- |
| 环境粒子、Bloom、CameraBlurPlane、LightBlur | 关 | 开 |
| Uber 后处理 | 开 | 开 |

原彩表示恢复色彩和后处理，不恢复未压缩或 HD 资源。

## 配置写入契约

界面状态与环境文件位于实际 UI 目录的 `state.txt` 和 `launch_config.env`。游戏配置始终从已确定的绝对 `GAMEDIR` 选择 `config.low.toml` 或 `config.original.toml`，缺少相应模式文件时使用 `config.toml`。

- 显示尺寸写 `[device]`；显式渲染比例写 `[gpu]`，保留已有滤镜。
- 显式帧率写 `unity.target_fps`，并设置 `unity.render_sleep_us = 0`，避免重复等待；忽略的旧 `unity.frame_sync_interval_us` 会删除。
- 内存档写 `[runtime]`；标题专用效果和装饰物写 `[game_patches.silksong_unity6]`。
- 标题后实验性批量卸载资源包固定关闭，不设菜单。
- 菜单退出保留游戏原有存档流程；引擎停止且偏好设置写入成功后直接结束进程，跳过耗时的资源析构。写入失败、异常和快捷键退出仍走完整清理。
- Rudroid 自动管理 ELF 文件映射及回退，不再提供无效的旧 `loader.file_backed_elf` UI 选项。

所有 TOML 更改经结构化原子合并，保留未知表、包路径和玩家设置；解析或保存失败则停止启动，不继续使用部分配置。

## 构建与分工

执行 `_kit/dist_port.sh silksong`，仅部署生成的 `dist/`。更新脚本、共享 Lua 和 `bin/portkit-launcher` 时应一起更新，保留设备的状态、游戏 TOML、存档和资源。

通用 ELF、图形、音频和输入能力由 Rudroid 提供；丝之歌专属裁剪放 `game_patches.silksong_unity6`；用户可调选项放本端口。新的实验项需要在目标设备留下同场景稳定性和性能证据后再决定默认值。
