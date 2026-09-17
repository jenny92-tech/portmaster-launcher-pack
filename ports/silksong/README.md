# 空洞骑士：丝之歌端口

本端口只维护启动器、设置界面和启动脚本模板；游戏运行时、UnityLoader、玩家资源和压缩后的 bundle 不放进本目录。

## 菜单入口

生成后的菜单脚本：

```text
K_空洞骑士_丝之歌[中].sh
```

常见部署位置：

- miniLoong/RK3566: `/userdata/silksong`
- Chuimi/1G: `/mnt/UDISK/silksong`
- Chuimi 菜单入口: `/mnt/SDCARD/Roms/PORTS/K_空洞骑士_丝之歌[中].sh`

## 弱机推荐配置

1 GiB 内存设备需要额外 1 GiB swap。已验证“1G RAM + 1G swap”可以进入游戏并游玩，但仍然依赖 swap，不是纯 1G 内存方案。

| 选项 | 推荐值 |
| --- | --- |
| 画面模式 | 低画 / 稳定 |
| 帧率上限 | 45 FPS；如果 swap 卡顿明显降到 30 FPS |
| 渲染比例 | 75%；性能兜底用 50% |
| 装饰物 | 75% |
| 实验：降低内存压力 | 开 |
| 实验：卸载资源包缓存 | 开 |

## 效果开关

效果页里的粒子和后处理项支持三态：

| 值 | 含义 |
| --- | --- |
| 跟随画面模式 | 低画使用弱机默认，原彩尽量恢复效果 |
| 开 | 强制开启该效果 |
| 关 | 强制关闭该效果 |

当前弱机默认等价于：

| 效果 | 默认 |
| --- | --- |
| 环境粒子 | 关 |
| Bloom | 关 |
| CameraBlurPlane | 关 |
| LightBlur | 关 |
| Uber 后处理 | 开 |

## 启动器写入的关键项

启动前会根据 LÖVE UI 选择写入 UnityLoader TOML：

- `unity.render_sleep_us = 0`
- `unity.frame_sync_interval_us` 对应 25/30/45/60 FPS
- `gpu.renderScalePercent` 对应 50/75/100
- `game_patches.silksong_unity6.decorative_sprite_percent`
- `game_patches.silksong_unity6.disable_touch_camera = true`
- `game_patches.silksong_unity6.disable_touch_controls = true`
- `game_patches.silksong_unity6.disable_watermark_canvas = true`
- `game_patches.silksong_unity6.disable_audio_preloader = true`
- `loader.file_backed_elf.enabled`

低画模式会关闭环境粒子和部分重后处理：bloom、camera blur plane、light blur；保留 uber postprocess，避免颜色/画面退化过头。

高级设置里的两个内存项均标为实验项，并默认开启，以优先照顾 1 GiB 设备；内存充足或稳定性优先时可手动关闭。

- `loader.file_backed_elf.enabled` 对应“实验：降低内存压力”，让部分 SO 映射更容易被系统回收/换页，可能让启动或转场变慢。
- `unload_assetbundles_after_title` 对应“实验：卸载资源包缓存”。该项曾在实验路径里有内存收益，不属于画质效果开关，可能影响转场或资源二次加载。

## 收敛规则

- 通用加载、ELF、EGL/GLES、音频、输入能力放 Bogodroid/UnityLoader。
- Silksong 专属裁剪放 `game_patches.silksong_unity6`。
- 用户可调参数放本端口 LÖVE UI。
- 原彩只表示恢复后处理/色彩，不表示恢复 HD 或未压缩资源。
- 新的低内存实验先在 Bogodroid `work/` 留证据，确认稳定后再进启动器。
