# 黑神话悟空像素版启动器

LÖVE 设置界面修改游戏 `config.toml` 后运行 Rudroid。
构建与运行目录规则见[共享工具](../../_kit/README.md)。

```sh
_kit/dist_port.sh heishenhua
```

只部署生成的 dist；loader、`rudroid.runtime/` 和 helper 按完整 kit 更新，
保留 UI 状态、配置、存档和玩家资源，不沿用旧 C 插件目录示例。

| 设置 | 写入/行为 |
|---|---|
| 渲染尺寸 | 保留游戏预设或显式 100/75/50，保留滤镜 |
| 内存 | `[runtime].memory_mode` 的低/均衡/高档 |
| 高级 → 纹理质量 | 低 / 中 / 高 / 原画，对应 textureMaxDim：384 / 480 / 720 / 0；像素滤镜 nearest |
| 高级其他项 | 输出尺寸、A/B、X/Y |
| 高级 → 修改 / 作弊 | 伤害/资源/冷却写游戏自己的 `[[il2cpp_patch]]` 配置，经通用 il2cpp_patch 实现 |

类名/方法/字段约束留在游戏配置；不另建 heishenhua_mods。
TOML 使用结构化合并，保留 paths、包路径和未知表。界面保留作者署名。
