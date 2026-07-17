# 黑神话悟空像素版启动器

给 Bogodroid 黑神话像素版使用的两阶段 PortMaster 启动器：Stage 1 使用
PortMaster 自带的 LÖVE 11.5 显示设置界面；Stage 2 按选择修改 `config.toml`
并运行 `unityloader`。

## 文件

| 文件 | 作用 |
|---|---|
| `love/main.lua` | 分辨率、画质、按键布局与修改选项；输出 `launch_config.env`。 |
| `love/conf.lua` | LÖVE 全屏和模块配置。 |
| `love/ui.gptk` | 设置界面的手柄到键盘映射。 |
| `love/launcher.sh.template` | 两阶段设备脚本模板。 |
| `dist/love_ui/` | 打包后的 LÖVE UI、共享 kit、背景和运行时字体缓存。 |

首次 LÖVE 启动会从旧 Godot userdata 的 `launch_config.env` 导入已有选择；
之后状态保存在 `love_ui/state.txt`。

## UI 选项 → config.toml

| UI 选项 | 值 | 字段 |
|---|---|---|
| 渲染分辨率 | auto/640x480/720x720/960x540/960x720/1280x720 | `displayWidth/Height` |
| 画面质量 | 384/480/720/0 | `textureMaxDim` |
| 换 A/B、换 X/Y | on/off | `[input.remap]` |
| 减伤、无限资源、技能冷却 | 多档 | `[[il2cpp_patch]]` |

## 构建与部署

```bash
_kit/dist_port.sh heishenhua
```

将 `dist/[中]黑神话悟空-像素版.sh` 放进 `Roms/PORTS/`，其余 `dist/`
内容放进 `Data/ports/heishenhua/`。设置 UI 使用 PortMaster
`runtimes/love_11.5`，不再需要 frt、hacksdl 或 `bootstrap.pck`。

界面左下角保留游戏、美术和移植作者署名，作者名按原文显示。
