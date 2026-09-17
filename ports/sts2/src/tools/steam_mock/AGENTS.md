# Steam 接口桩生成

> 从 Steam 包装源码生成 ARM64 动态链接符号桩。

## 地位

为掌机端提供原生 Steam API 缺省返回值的构建工具。

## 逻辑

gen_stubs.py 解析 flat.cpp/dll.cpp 导出签名，按返回类型和少量显式覆盖生成 C 源码。

## 约束

- 生成文件和编译库不手工补文档，维护生成器即可。
- 依赖外部 gbe_fork 源码，不能把桩实现当作真实 Steam 服务。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| gen_stubs.py | `gen_stubs.py` | 按返回类型与显式覆盖生成 ARM64 离线 Steam 接口桩 |
| README.md | `README.md` | 生成与构建流程及接口桩定位 |
| .gitignore | `.gitignore` | 生成源码和动态库产物忽略规则 |

