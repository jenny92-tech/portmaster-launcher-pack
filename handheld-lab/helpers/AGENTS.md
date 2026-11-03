# Linux 设备能力提供器

以 uinput、evdev 和 framebuffer 补充目标系统能力。三个 C 工具由统一脚本编译，Alpine/Docker 包装负责生成 amd64 或 arm64 静态产物。

## 约束

- 工具依赖 Linux 设备接口及对应权限；构建宿主与运行目标分开处理。
- 虚拟输入设备由创建者释放，事件观测具有时间或数量边界，截图读取实际 framebuffer。
- `build/` 是生成输出；编译容器及工具链不属于设备运行依赖。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 输入注入 | `handheld-input.c` | probe/tap/serve 与虚拟输入设备生命周期 |
| 输入观测 | `handheld-event.c` | 按设备名称匹配并限时读取事件 |
| 帧缓冲截图 | `handheld-fbshot.c` | 读取 framebuffer 并输出 PPM |
| 统一编译 | `build-input-helper.sh` | 编译三个辅助程序并可选静态链接 |
| Alpine 编译 | `build-in-alpine.sh` | 准备 Linux 工具链后调用统一编译 |
| 双架构编译 | `build-linux-helpers.sh` | 通过 Docker 生成 amd64/arm64 产物 |
