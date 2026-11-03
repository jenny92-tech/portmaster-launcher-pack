# STS2 TrimUI 0.110.1 桥接

离线生成独立托管兼容 DLL，供旧 SDL Godot fork 与游戏侧官方入口协作；不重编引擎或更改玩家原文件。

| 文件 | 职责 |
| --- | --- |
| `Bridge.csproj` | 使用显式给出的已有 Mono.Cecil 路径 |
| `Program.cs` | 固定输入 SHA，仅消除 fork 早期回调并复核其他方法与嵌入资源 |
