# 余烬灯塔打包回归

使用临时 PCK 和数据夹具，不执行游戏或原生图形库。

## 约束

- 维持 `emberward/conf` 存档位置，不收集 conf、预览工具、缓存或挂载的 runtime。
- Godot/Weston 继续由 PortMaster 管理；共享 WSI 从 `_kit/compat/` 归档读取。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 负载边界 | `test_package.py` | 验证不携带相邻档案、错误输入拒绝和 WSI 私有清单 |
