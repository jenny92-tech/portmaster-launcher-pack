# 启动辅助的命令与文件操作

`bin.rs` 将有限子命令分派给库模块，封面、字体、配置及同步操作复用本目录的原子文件工具。运行库选择只读取已安装版本，设备封面写入限定于已验证的前端布局。

## 约束

- 实现不依赖 APP 管理服务或包含 HTTP/TLS 的 `portkit-core`。
- JSON/TOML 编辑保留未知字段与文本；字体提取校验归档成员名、格式及大小。
- Unity 显示、GPU、内存、按键分别写入 `device`、`gpu`、`runtime`、`input.remap`；按结构定位，不按文本位置猜层级或误写到根表。
- 非法 TOML、参数和类型冲突在原子替换前拒绝；未知设备不推测封面目标目录。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 库入口 | `lib.rs` | 暴露启动辅助功能模块 |
| CLI 入口 | `bin.rs` | 解析参数、分派子命令并报告结果/退出码 |
| 封面同步 | `artwork.rs` | 识别已验证布局并同步启动器图片 |
| 原子文件 | `atomic.rs` | 不引入共享网络核心的持久化写入/复制 |
| 字体供给 | `font.rs` | 复用现有字体或从受限归档提取字体 |
| JSON 编辑 | `json.rs` | 深度合并对象并原子保留未知配置字段 |
| TOML 编辑 | `toml.rs` | 保留格式与未知表的有类型合并，null 删除指定键 |
| Runtime 选择 | `runtime.rs` | 按自然版本顺序查找最新已安装 LOVE 运行库 |
| 增量同步 | `sync.rs` | 按扩展名和修改时间复制较新资源 |
| Unity 配置 | `unity.rs` | 固定配置表中的显示、渲染、内存和按键更新与尺寸报告 |
| Unity 后端 | `unity_graphics.rs` | 原子选择 GLES/Vulkan，保留 GLES 滤波和启动参数，独立校验 Vulkan 线性缩放策略 |

原生会话共用同一 CLI；标题参数保存在安装清单，不编译设备名称或游戏调优到公共辅助程序。静态 musl 辅助程序只执行独立 GNU/Linux 图形预检器，不在自身加载 SDL/Vulkan。开发执行视图只编译到独立 `portkit-debug-launch`，不由正式 CLI 暴露、不进入游戏包；它仅改私有命名空间的 noexec。Shell 可以初始化官方 SDK、编排共享适配器并等待 helper；游戏进程组、关闭日志后的信号转发、回收与失败清理仍由原生 owner 管理，不能绕过 helper 分离启动游戏。

| 原生设备会话 | `native_cli.rs`、`session.rs` | 声明式安装校验、档案锁、参数/环境、诊断与退出码 |
| 子进程所有权 | `process.rs` | setsid、父进程退出保护、信号唤醒、64 KiB 日志尾部与定向回收 |
| 开发入口 | `debug_bin.rs`、`exec_view.rs` | 独立调试程序，保留 PID、参数和其它挂载标志；Release helper 不链接 |
| 缺失显示能力 | `wayland_session.rs` | 审计客户端、系统 GNU ABI、独占 Weston 生命周期与挂载清理 |
| 驱动审计 | `driver.rs` | 显式 malisx2 来源、散列与 Linux ELF 导入验证，不加载驱动 |

官方 PortMaster 状态和固件恢复继续由共享 Shell 模块维护，不另建原生 SDK RPC 桥。菜单桥可使用 Bash `exec -a`，保留同一 PID 与固件 `.port.sh` 命令行身份；SDK、显示预检、游戏和收尾期间都不能提前释放前台 owner。正常、失败和信号退出都收尾，不复制官方脚本到游戏包。

`bounded --seconds N -- COMMAND` 复用进程 owner 的事件与截止时间，不能假设固件具有 coreutils timeout、BusyBox timeout 或 getconf。私有会话挂载复用已有信号 guard；释放后才建立清理 guard，避免嵌套死锁，取消后的卸载仍须执行。
