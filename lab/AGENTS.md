# App Manager 设备评估

> 验证 App Manager 的配置、服务、UI 与真实固件用户态兼容性。

## 地位

通用 handheld-lab 的应用侧消费者，专注管理器业务而非通用设备控制。

## 逻辑

由正式 Config 派生识别夹具，配合显式采集的 loader/运行库在 ARM64 容器中运行服务与 UI；pam_lab 汇总检查报告，独立 Web fixture 提供稳定页面数据。

## 约束

- 正式 config/ 是唯一设备策略来源，不维护第二套平台路径或识别规则。
- 用户态检查不能证明物理 GPU/DRM、音频、手柄和固件恢复正常，仍需真实设备验证。
- 证据采集只针对显式目标和有限路径，不读取凭据或递归扫描用户存储。
- 不要在文档维护中运行部署、设备采集或容器用户态测试；普通回归优先 tests/。
- pam_lab.py 的 doctor 模式也会启动 Docker ARM64 基础探测，test/diagnose 还会执行完整设备容器矩阵，均不是纯静态检查。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 使用说明 | `README.md` | 评估覆盖、外部用户态输入和执行方式 |
| 评估入口 | `pam_lab.py` | doctor/test/diagnose 检查编排与报告归档 |
| 设备证据采集 | `collect_device_evidence.py` | 通过 ADB/SSH 运行有界探针并可选收集运行库 |
| 设备探针 | `device-probe.sh` | 只读输出有限设备与安装事实 |
| 识别夹具 | `prepare_device_fixture.py` | 从正式配置和观测启动路径生成测试环境 |
| ARM64 基础测试 | `run-arm64-tests.sh` | 容器执行服务/配置回归 |
| 设备业务测试 | `run-device-function-tests.sh` | 真实 loader/libc 下执行业务、E2E 和 UI 检查 |
| 设备用户态验证 | `run-device-userspace.sh` | 检查动态依赖与完整 UI 首帧 |
| 容器内冒烟 | `userspace-container-smoke.sh` | 验证服务/Lua/首帧及实际平台选择 |
| Cargo 设备运行器 | `device-cargo-runner.sh` | 使用采集的设备 loader 执行 Rust 测试 |
| 输入辅助包装 | `gptokeyb-loader-wrapper.sh` | 以指定设备 ABI 运行输入辅助程序 |
| 浏览器夹具 | `serve-appmanager-web-fixture.py` | 真实 HTML 搭配固定 API 状态的评估服务器 |
| 本地测试 | `tests/` | 证据解析与评估报告回归 |
