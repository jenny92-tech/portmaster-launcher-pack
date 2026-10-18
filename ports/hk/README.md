# 空洞骑士启动器

LÖVE 设置界面应用用户选择后运行 Rudroid 的 `unityloader` 入口。
通用构建、运行目录及配置契约见[共享工具](../../_kit/README.md)。

```sh
_kit/dist_port.sh hk
```

部署生成的 SH 和端口负载；loader 与 `rudroid.runtime/` 必须来自同一审计 kit。
不要按旧 C 版 `unityloader.d/` 示例单独拼库。资源和存档保留原位置。
FMOD 桥和 Hollow Knight 视口插件分别负责音频与 4:3 相机/tk2d 适配。

| 设置 | 行为 |
|---|---|
| 渲染尺寸 | Game preset 保留精确/比例尺寸；100/75/50 保留滤镜，并同步游戏视频设置 |
| 内存 | `[runtime].memory_mode`：low_memory / balanced / performance |
| 高级 → 纹理质量 | 低 / 中 / 高 / 原画，对应 textureMaxDim：384 / 512 / 720 / 0 |
| 高级其他项 | 输出尺寸、A/B、X/Y 交换 |

状态保存在实际 `love_ui/state.txt`，旧设置仅首次导入。
视频配置同步保留语言、音频和非启动器字段。实测应覆盖界面单步导航、设置持久化、
游戏移动/动作、视口、声音与正常退出。
