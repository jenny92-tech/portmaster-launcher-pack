# 龙沉异世录启动器

这是《龙沉异世录》（Windows 标题：Sunken Dragon）的实验性
PortMaster/Bogodroid 启动器。设置界面使用 PortMaster 自带的 LÖVE 11.5，
游戏使用 ARM64 Linux `unityloader`。

## 必须自行购买 Windows 正版

本端口不是独立游戏包。玩家需要从官方渠道购买并下载 Windows 版，然后把完整
游戏目录复制到设备：

```text
Data/ports/sunkendragon/GameData/
├── Sunken Dragon.exe
├── GameAssembly.dll
├── UnityPlayer.dll
└── Sunken Dragon_Data/
```

当前验证包先携带完整 Android `gamefiles/` 基线，以证明掌机运行链稳定。玩家仍需
把正版 Windows 游戏放进 `GameData/` 作为购买与文件来源要求；原始目录不会被修改
或删除。游戏更新后，如提示版本不支持，请先在官方客户端校验文件，再等待端口
适配，不要从第三方下载缺失文件。

完整基线稳定后，才会逐项验证哪些场景、美术、音频资源能够从玩家自己的 Windows
正版目录迁移，并逐项从端口包删除。实验性的最小迁移脚本仍保留，但不作为当前
发布基线。

## 构建当前完整基线

```bash
ports/sunkendragon/src/scripts/stage-full-package.sh
```

默认从相邻的 Bogodroid 工作区读取完整 Android 重建数据、已验证的
`unityloader`、ARM64 Steam API stub 和安全失败的加密票据 companion，输出到 Git 忽略的
`ports/sunkendragon/dist/`。

两个 staging 脚本会从 loader 所在构建目录同时复制匹配的
`unityloader.libs/`，以及本端口最小插件集：`android_base`、
`unity_2021_3`、`platform_sdl_runtime`、`sdk_unity_burst`。不能只替换
`unityloader` 单个文件。

后续逐文件删减实验使用：

```bash
ports/sunkendragon/src/scripts/stage-minimal-package.sh
```

## 部署

- `dist/L_龙沉异世录[中].sh` 放到 `Roms/PORTS/`。
- `dist/` 其余内容放到 `Data/ports/sunkendragon/`。
- 玩家再把 Windows 正版完整目录复制进 `Data/ports/sunkendragon/GameData/`。

## 当前验证状态

完整 Android ARM64 数据已在 TrimUI 上进入持续渲染；原先首次渲染后的闪退定位为
Unity 内置 Swappy 请求掌机 EGL 驱动不提供的 `eglPresentationTimeANDROID`，
Bogodroid 现由 SDL 接管呈现时间并通过了 30 秒受控运行测试。Steamworks.NET 所需
普通原生入口已由 ARM64 API stub 覆盖；单独的 11 个加密票据入口返回安全失败值，
不伪造 Steam 票据。端口仍保持 experimental 标记，等待更长时间
游玩验证和后续正版 Windows 资源逐项迁移。

这条路线不是把 Windows `GameAssembly.dll` 改名成 `.so`，而是用恢复工程重新
生成 ARM64 `libil2cpp.so`，再以正版 Windows 目录作为资源来源和安装门槛。
