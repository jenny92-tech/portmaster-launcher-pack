# 丝之歌启动界面

> 定义丝之歌画面模式、帧率、渲染比例、低内存和按键选项。

## 地位

丝之歌移植的 LÖVE 设置层与 Unity 6 启动模板。

## 逻辑

Lua 声明输出 SILK_* 参数；Shell 模板定位既有游戏目录，安装字体 fallback，选择低画/原彩 TOML，写入 Unity、GPU、game patch 和 file-backed ELF 配置，再调用共享 Unity 启动器。

## 约束

- UI 的显示环境与 Unity 游戏环境隔离；通用运行逻辑交由 `_kit/`。
- 模板必须兼容既有 `/userdata/silksong` 与 `/mnt/UDISK/silksong` 部署路径。
- 优先使用端口包内的 `love_ui`；未安装独立 UI 包时使用游戏目录内的 UI 与 PortKit，保留原设置位置。
- 内存相关选项必须明确标实验；默认开启以优先适配 1 GiB 设备，内存充足时可由用户手动关闭。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 选项定义 | `main.lua` | 声明画面模式、帧率、渲染比例、装饰比例、效果开关、file-backed ELF 和按键配置 |
| 启动模板 | `launcher.sh.template` | 定位游戏目录、写 TOML 设置、应用效果开关并启动 UnityLoader |
