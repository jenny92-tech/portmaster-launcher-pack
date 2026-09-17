# 设备配置契约

> 集中维护 App Manager 的平台识别、路径、环境和安装安全策略。

## 地位

供原生 PortKit 和管理核心消费的唯一设备配置来源。

## 逻辑

人工维护 src 片段，经 scripts/generate.py 生成 config.json 与 platforms 详情；根描述绑定详情字节数和散列，生产验证器与 Rust 加载器共同约束契约。

## 约束

- 只修改源片段后重新生成，不手工修改生成 JSON。
- 平台策略保持有限声明式词汇，不允许 Shell/eval 逃逸。
- 版本、Schema 和发布元数据不随内部结构或文档变化自动升级。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 配置说明 | `README.md` | 格式、生产命令和安全边界 |
| 源片段 | `src/` | 人工维护的全局规则、适配器与平台配置 |
| 根配置 | `config.json` | 原生嵌入的生成根契约及详情绑定 |
| 平台详情 | `platforms/` | 按平台生成、按需加载的外部详情 |
| 根 Schema | `appmanager-config.schema.json` | 根配置及跨字段约束说明 |
| 详情 Schema | `platform-detail.schema.json` | 平台详情结构约束 |
| 生产工具 | `scripts/` | 配置生成与校验 |
| 契约测试 | `tests/` | 生成、模型及安全策略回归 |

