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
| `dist/love_ui/` | 打包后的 LÖVE UI、共享 kit 和背景；字体直接复用 PortMaster 系统资源。 |

首次 LÖVE 启动会从旧 Godot userdata 的 `launch_config.env` 导入已有选择；
之后状态保存在 `love_ui/state.txt`。

## UI 选项 → config.toml

| UI 选项 | 值 | 字段 |
|---|---|---|
| 输出分辨率 | auto/640x480/720x720/960x540/960x720/1280x720 | `[device].displayWidth/Height` |
| 渲染分辨率 | 原生/75%/50% | `[gpu].renderScalePercent` + 锐化上采样 |
| 画面质量 | 384/480/720/0 | `textureMaxDim` |
| 交换 A/B、交换 X/Y | on/off | `[input.remap]` |
| 减伤、无限资源、技能冷却 | 多档 | `[[il2cpp_patch]]` |

触屏 HUD 隐藏/移动和上面的数值修改现在由同一个通用
`il2cpp_patch.so` 提供；类名、方法名和字段偏移仍只写在本游戏的
`config.toml`，不再需要 `heishenhua_mods.so`。

像素纹理固定使用 `textureDownsampleFilter = "nearest"`，保留硬边并降低启动时
缩放开销；纹理尺寸上限仍由画面质量选项控制。

## Bogodroid 运行文件

```text
unityloader
unityloader.libs/
  libstdc++.so.6
  libgcc_s.so.1
unityloader.d/
  android_base.so
  unity_2021_3.so
  platform_sdl_runtime.so
  sdk_unity_burst.so
  il2cpp_patch.so
```

需要详细诊断时可额外放入 `platform_log_stderr.so`；正常发布不必携带。
`unityloader.libs/` 是 loader 和所有插件共用的一份工具链运行库，必须和
本次构建的 `unityloader`、插件一起更新。

## 构建与部署

```bash
_kit/dist_port.sh heishenhua
```

将 `dist/[中]黑神话悟空-像素版.sh` 放进 `Roms/PORTS/`，其余 `dist/`
内容放进 `Data/ports/heishenhua/`。设置 UI 使用 PortMaster
`runtimes/love_11.5`，不再需要 frt、hacksdl 或 `bootstrap.pck`。

界面左下角保留游戏、美术和移植作者署名，作者名按原文显示。
