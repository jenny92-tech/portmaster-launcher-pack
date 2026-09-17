# Linux 原生辅助工具

> 为输入注入、事件观测与帧缓冲截图提供小型 Linux 工具。

## 地位

补足目标系统原生命令不足的 provider 层，不依赖 App Manager。

## 逻辑

C 程序分别调用 uinput、evdev 与 framebuffer 接口；统一构建脚本可在 Alpine 容器中生成 amd64/arm64 静态二进制。

## 约束

- 需要 Linux 设备接口与对应权限，macOS 不能直接编译运行这些系统头文件。
- 输入辅助程序销毁虚拟设备，事件观测有时间/数量上限，截图读取实际 framebuffer。
- 生成二进制放在 build/；容器镜像与编译器不是设备最小运行依赖。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 输入注入 | `handheld-input.c` | probe/tap/serve 与虚拟输入设备生命周期 |
| 输入观测 | `handheld-event.c` | 按设备名称匹配并限时读取事件 |
| 帧缓冲截图 | `handheld-fbshot.c` | 读取 framebuffer 并输出 PPM |
| 统一编译 | `build-input-helper.sh` | 编译三个辅助程序并可选静态链接 |
| Alpine 编译 | `build-in-alpine.sh` | 准备 Linux 工具链后调用统一编译 |
| 双架构编译 | `build-linux-helpers.sh` | 通过 Docker 生成 amd64/arm64 产物 |

