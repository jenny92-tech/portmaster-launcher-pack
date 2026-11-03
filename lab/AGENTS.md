# APP Manager 评估编排

复用 `handheld-lab` 的设备控制能力，以正式配置生成应用夹具，再用显式采集的 loader 和运行库执行 ARM64 用户态检查。服务、UI 和浏览器夹具的结果由 `pam_lab.py` 汇总。

## 约束

- 设备识别和路径策略来自 `config/`；评估夹具只补充观测事实。
- 采集范围限定为指定目标与文件白名单，外部用户态输入与源码分开保存。
- `doctor` 会执行 Docker 基础探测，`test/diagnose` 会运行设备容器矩阵；命令选择须与实际验证层级一致。
- 容器结果覆盖用户态行为；物理显示、声音、控制器及固件恢复另行验收。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 使用说明 | `README.md` | 评估覆盖、外部用户态输入和执行方式 |
| MiniLoong 执行策略 | `EXECUTION.md` | 固件执行窗口、noexec、私有视图及 APP Manager 会话交接契约 |
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
| 浏览器夹具 | `serve-appmanager-web-fixture.py` | 真实 HTML 搭配固定 API 状态，支持六位路径自动配对评估 |
| 本地测试 | `tests/` | 证据解析与评估报告回归 |
