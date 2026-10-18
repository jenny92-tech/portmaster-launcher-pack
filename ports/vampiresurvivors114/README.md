# 吸血鬼幸存者 1.14.111

Android Unity 6/IL2CPP 版本，通过 Rudroid 运行；不要混用其他游戏版本资源。
SH 入口仍为 `V_吸血鬼幸存者_114.sh`，设置/打包规则见[共享工具](../../_kit/README.md)。

## 资源布局

```text
gamedata/lib/arm64-v8a/*.so
gamedata/assets/bin/Data/data.unity3d
gamedata/assets/bin/Data/Managed/Metadata/global-metadata.dat
gamedata/assetpacks/UnityDataAssetPack/assets/bin/Data/datapack.unity3d
gamedata/assetpacks/UnityDataAssetPack/assets/aa/settings.json
```

从玩家自己的 base APK 和 UnityDataAssetPack 分别解出；PAD 不能合并到 base/assets，
两边可能有同名文件。`paths.game_files` 指向 `gamedata`。Java/NDK/native 资源解析
和 Play Core/GMS 兼容由 Rudroid 负责，不在启动器复制或增加下载流程。

## 一次准备资源

在 Rudroid 根目录执行，GPU 必须支持 ASTC：

```sh
.venv-unity/bin/python tools/unity_assets.py /games/original/gamedata /games/my-port/gamedata
```

默认 1 GiB，外部程序可用 `--target astc-2g` / `astc-4g`。输出须是新目录，保留全部
base/PAD、sidecar 和原生库；自动质量回退，不改原图尺寸或丢 mip。
本游戏 `textureMaxDim` 固定 0；曾改变可见视口，优先用离线转换。

## 启动与验证

`_kit/dist_port.sh vampiresurvivors114` 生成 dist。SH 放到固件 Ports 菜单，
其余负载放实际端口目录；整套 loader＋`rudroid.runtime/` 按同 kit 更新，
不使用旧 C 版 `unityloader.d/` 清单。保留配置、UI 状态、存档和玩家资源。

常用页是渲染尺寸和内存档；输出尺寸、A/B、X/Y 在高级。
高级页按实际环境开放实验 Vulkan，支持与 GLES 共用的 100% / 75% / 50%
渲染和内存档。默认 OpenGL ES 3.0；不支持的后端不能选择，已存无效值在
显示前改为可用默认值。滤波自动处理，不适用项显示“禁用”，不替换系统驱动。
手柄由 Rudroid 原生接入，设置 UI 退出后不保留额外键盘映射或强杀器。
Start 暂停，Select+Start 交给原生退出流程。验收覆盖警告确认、菜单、进入关卡、移动、音频和正常退出，
不同页面的提交率不能直接比较。
