# MiniLoong 执行视图与会话交接

本页说明 LoongOS 启动链与项目适配边界。固件结论来自 LoongOS 1.4.0.36 的有限
反汇编和运行中挂载观察，不能推广为所有版本或所有掌机的能力。

## 两条启动路径

正常首页启动由固件 `GameLauncher::openProgram()` 检查启动工作目录对应的 TF
挂载点；若包含 `noexec`，临时重新挂载为 `exec` 并记住该路径。
`closeProgram()` 进入关闭流程时恢复 `noexec`，部分启动失败路径也会恢复。
观察到的授权作用于同一 mount namespace 中匹配的整个 TF 挂载点，不是逐文件授权。
恢复可能早于全部子进程结束，运行器需要维持正确的官方会话生命周期。

ADB 或独立调试入口可能没有这个执行窗口。它们应使用已准备的内部运行时，
或显式使用 [_kit/launch_exec_view.py](../_kit/launch_exec_view.py) 创建私有执行视图。
辅助程序、宿主共享库和后续动态加载均须经过适当视图；首个 Shell 能启动不足以证明整条链可用。
不要把调试入口的前提加入正常首页流程，也不要永久改变整张卡的执行策略。

## APP Manager 交接契约

固件的进程跟踪会缓存启动 PID。管理器保留 Shell 为 UI 父进程，UI 请求游戏后
以约定状态退出，原 Shell 清理交接信息并 `exec` 目标脚本，保持同一 PID：

```text
固件 → APP Manager Shell → LOVE-lite UI
                  └─ UI 返回后 exec 游戏脚本 → 游戏及辅助进程
```

[launcher.sh](../ports/appmanager/src/launcher.sh) 负责原 shebang、工作目录、环境和
退出码交接；[启动器回归](../tests/test_appmanager_thin_launcher.sh) 验证这些进程语义。
管理器 UI 退出不等于整个游戏会话结束。SDK 的 `EventOpend("GAME")` 是就绪通知，
不是通用挂载授权接口。

## noexec 的机制边界

| 情形 | 执行条件 |
|---|---|
| `chmod +x` | 修改文件 mode，不清除挂载视图的 `noexec` |
| 系统 Bash 读取卡上的脚本 | 解释器可执行、脚本文本可读；脚本随后启动的 ELF 仍受执行检查 |
| glibc 加载 ELF 或 `.so` | 文件后备的可执行段映射也受 `noexec` 限制；直接运行系统动态链接器不是通用解法 |
| bind/mount namespace | 必须检查 capability、传播属性、子挂载和最终访问路径；普通 bind 不自动获得 exec |
| 自定义 ELF 加载器 | 匿名复制、重定位和依赖加载另有实现及内存代价，不能由 glibc 行为推定 |

机制依据：[Linux exec 检查](https://github.com/torvalds/linux/blob/adc218676eef25575469234709c2d87185ca223a/fs/exec.c)、
[Linux mmap 检查](https://github.com/torvalds/linux/blob/adc218676eef25575469234709c2d87185ca223a/mm/mmap.c)、
[util-linux mount 语义](https://github.com/util-linux/util-linux/blob/1cebcc34373ed34266f726fff71030a83b4df7da/sys-utils/mount.8.adoc)、
[Bash 脚本调用](https://www.gnu.org/software/bash/manual/bash.html#Shell-Scripts)。

## 验证范围

首页 → APP Manager → 游戏 → 正常退出的完整验证，需要同时观察跟踪 PID、实际访问路径、
各进程的 mount namespace、TF 标志及退出后的恢复。容器和主机替身只能验证局部进程语义。
其他固件、卡槽、挂载点及异步脱离的运行器须分别验证；不以 IP 地址或 UID 判断兼容性。
固件采集件、进程快照及私有实验记录保留在公开源码之外。
