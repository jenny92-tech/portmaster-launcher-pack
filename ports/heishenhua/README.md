# 黑神话悟空像素版启动器 (sts2-style, PoC)

PortMaster 两阶段启动器, 给 Bogodroid 黑神话像素版用, 改自 hk-launcher
模板。Stage 1 是 GDScript 选项 UI (`bootstrap.pck`); Stage 2 sed 改
`wsm.toml` 然后跑 `unityloader`。

字体: 从游戏 bundle 里取出 Fusion Pixel (林学学提供的像素字体),
pyftsubset 子集到 launcher 用得到的 129 个 codepoint, 16 KB。

## 文件

| 文件 | 作用 |
|---|---|
| `src/launcher_ui.gd` | 选项 UI: 分辨率 / 画面质量 / 换 A·B / 换 X·Y。写 `launch_config.env`, 退出码 42 启动游戏。 |
| `src/manifest.bootstrap.json` | 打包 project.godot + tscn + gd + 背景 + 字体 → `dist/bootstrap.pck`。无需 Godot Editor。 |
| `src/assets/launcher_font_zh.ttf` | Fusion Pixel subset (从游戏 m_FontData 取的, 跟游戏内字体同源)。 |
| `src/assets/launcher_bg.png` | 启动器背景图 (可换)。 |
| `src/launcher.sh` | 两阶段 port script 模板。 |
| `dist/` | 生成后的设备文件集合。`*.sh` 推到 `Roms/PORTS/`, 其它文件推到 `Data/ports/heishenhua/`。 |

## UI 选项 → wsm.toml 映射

| UI 选项 | 值 | wsm.toml 字段 |
|---|---|---|
| 渲染分辨率 (auto/640x480/720x720/960x540/960x720/1280x720) | — | `[device] displayWidth/Height` |
| **画面质量** 低 | 384 | `[gpu] textureMaxDim` |
| **画面质量** 中 (默认) | 480 | `[gpu] textureMaxDim` (512 部分场景闪退 → 480) |
| **画面质量** 高 | 720 | `[gpu] textureMaxDim` |
| **画面质量** 极致 | 0 (关 cap) | `[gpu] textureMaxDim` ⚠ 1 GB 设备会 OOM |
| 换 A/B, 换 X/Y | on/off | `[input.remap] a/b/x/y` |

## 部署

先生成设备包:

```bash
_kit/dist_port.sh heishenhua
```

部署规则:

1. 把 `dist/[中]黑神话悟空-像素版.sh` 推到设备 `Roms/PORTS/`。
2. 把 `dist/` 里其它文件推到设备 `Data/ports/heishenhua/`。
3. Godot 用 PortMaster 自带的 squashfs runtime。设备上验证存在: `ls $controlfolder/libs/frt_3.*.squashfs`。

没有 godot / bootstrap.pck 时, launcher.sh 跳过 UI 直接跑游戏 — 删
`bootstrap.pck` 就是安全回滚。

## 字幕 (左下角)

```
游戏原作者: bili 火山哥哥
字体原作者: bili 林学学LinkLin
移植作者:    bili 解腻Jenny
```

作者名按原文保留, 不翻译。
