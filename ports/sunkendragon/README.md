# 龙沉异世录实验端口

按维护者要求暂停，不列入当前开发任务或 Rudroid 交付验收。现有工具留作参考；
只有取得可直接复用的原生版本或完整 Unity 源工程等简单路线时再评估。

Windows→Android ARM64 的逻辑恢复尚未完成，不在五个正式 Rudroid 标题验收内。
旧记录只证明开场垂直切片/持续渲染，不代表完整剧情、战斗与存档正确。
资源压缩不能补全缺失逻辑；恢复工具及必要错误见
[Bogodroid unity-convert](../../../Bogodroid/tools/unity_convert/README.md)。

玩家须提供自己的完整正版 Windows 目录，原始文件保持只读：

```text
GameData/Sunken Dragon.exe
GameData/GameAssembly.dll
GameData/UnityPlayer.dll
GameData/Sunken Dragon_Data/
```

## 开发组装

- `src/scripts/stage-full-package.sh`：当前完整 Android 重建基线。
- `src/scripts/stage-minimal-package.sh`：独立的实验性玩家资源迁移路径。

这两条开发路线不能当作通用资源转换开关。默认读取相邻 Bogodroid 工作区的
重建数据、匹配 loader/插件和两个 ARM64 Steamworks companion，输出到忽略的 dist。
companion 需正确 ABI；加密票据入口返回失败，不伪造验证结果。
本端口仍是独立实验基线，不按五标题 Rust 安装状态推断它已迁移完成。

生成的 `L_龙沉异世录[中].sh` 放固件 Ports 菜单，其他负载放实际端口目录。
运行库整套更新，保留用户配置和存档；后续每次逻辑恢复须对照 Windows 原版复验。
