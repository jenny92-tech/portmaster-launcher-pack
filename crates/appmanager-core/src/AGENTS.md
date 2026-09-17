# APP Manager 业务内核

> 将设备契约、文件清单和用户操作收敛为受限的原生事务。

## 地位

`appmanager-core` 的实现层，由进程内服务复用；通用配置和下载传输来自 `portkit-core`。

## 逻辑

设备解析生成已验证上下文；清单扫描提供事实，安装计划限制目标路径，安装、文件管理和 Runtime 修复通过文件锁、取消信号与进度通道协作。

## 约束

- 配置是数据，不作为 Shell 代码执行；写操作必须检查能力与托管路径。
- 归档读取保持条目、字节和路径限制；事务恢复不得把同名替换物误认成原对象。
- 共享目录关联使用精确路径，不能使用显示名作为删除依据。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 库入口 | `lib.rs` | 装配模块并重导出领域类型和业务接口 |
| 归档后端 | `archive_bundle.rs` | ZIP/7z 识别、目录唯一性校验、选择读取与有界解压 |
| 归档文件名 | `archive_names.rs` | Unicode 优先、旧 ZIP 编码自动检测，供扫描与解压统一使用 |
| 发布资源 | `artifact.rs` | 稳定版发布包契约、下载和元数据缓存策略 |
| 设备上下文 | `context.rs` | 管理能力、托管根目录、前端和安装契约及校验 |
| 设备解析 | `device.rs` | 从配置候选与设备探测构建共享领域视图 |
| PortMaster 安装 | `installer.rs` | 分阶段解压、前端转换、事务替换与恢复 |
| 资源清单 | `inventory.rs` | 按配置根和实际路径关联 Port/共享数据及残留；合并元数据与托管路径 Runtime 依赖 |
| Shell 路径后端 | `shell_paths.rs` | Bash 静态路径及托管 libs 镜像关联；随包 runtimes 不进入镜像修复，不执行脚本 |
| Shell 输入边界 | `shell_sources.rs` | 显式 source 根、描述符相对只读加载及离线设备快照 |
| Shell 抽象求值 | `shell_eval.rs` | 有界语法缓存和求值；按 AST 证明纯等待无路径影响，其余未知保持阻断 |
| Shell 回归 | `shell_paths_integration_tests.rs` | source 边界、分支、库路径和官方语料测试 |
| 文件管理 | `operations.rs` | 托管文件回收、恢复、删除及 AppleDouble 清理 |
| 路径边界 | `path.rs` | 托管根与子路径检查，拒绝越界和危险符号链接 |
| 安装计划 | `plan.rs` | 从上下文构造并校验可执行计划，提供 TSV 编解码 |
| 安装包业务 | `port_zip.rs` | 独立显式符号布局识别与安装 Port/TrimUI APP 包，处理诊断与事务恢复 |
| 契约映射 | `resolution.rs` | 将 PortKit 解析结果映射为 APP 专属上下文 |
| Runtime 修复 | `runtime.rs` | 官方元数据解析、镜像下载校验和可回滚替换 |
| 存储发现 | `storage.rs` | 从挂载表、sysfs 与别名识别用户存储根 |
| 任务通道 | `task.rs` | 进程内取消标志与合并式最新进度传递 |
