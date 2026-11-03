# 植物大战僵尸年度版

维护版引擎由独立 PvZ-Portable 工程提供，构建说明见该工程的 `portmaster/README.md`。
Pack 维护 `Je-植物大战僵尸年度版[中].sh`，设备目录继续为 `pvz_portable_jenny/`。

构建启动器用 `_kit/dist_port.sh pvz_portable_jenny`。提供 `PVZ_PORTABLE_RUNTIME=/path/to/engine-bundle` 时只收集引擎、libs.aarch64、gconv 和 licenses；始终不收集 main.pak、properties、userdata、cache64 或 registry.regemu。

玩家自行将正版 GOTY 的 main.pak 与 properties/ 放入游戏目录。旧档案路径保持不变，发行包不含存档。引擎改动通过原工程 Release 构建，不在 Pack 复制引擎源码。
