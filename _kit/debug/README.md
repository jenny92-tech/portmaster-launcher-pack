# 显式远程调试启动

仅供开发者；游戏 Release 不收录本目录，也不要求安装此工具。迷你龙远程 shell 可能缺少固件菜单准备的 SD 执行视图，需要时才使用本入口。

`build.sh` 用现有 Rust 构建器生成独立 `runtime/portkit-debug-launch.aarch64`、SHA-256 和源码身份。它与正式 `portkit-launcher` 是不同可执行文件；正式程序没有 `exec-view` 子命令。两者采用相同的优化构建，不把“启动调试用途”混同为未优化游戏二进制。

在设备开发目录中放入 `run.sh`、`launcher.sh` 与 `runtime/`，显式执行：

```sh
bash /userdata/portkit-debug/run.sh /roms/ports/soulknight_ns -- \
  /bin/bash /roms/ports/Je-元气骑士_ns.sh --check
```

该入口校验独立开发工具，必要时仅缓存它，再以原 PID 交接原命令；参数按字面传递，退出状态保留。只改变自己的挂载命名空间，不能将调试通过记为固件菜单点击验收。`PORTKIT_DEBUG_LAUNCHER` 仅供显式指定另一份独立开发工具，其相邻 `.sha256` 必须匹配。
