# STS2 着色器覆盖资源

构建脚本将 mobile_compat 中的 shader 放入 `res://shaders/mobile_compat`；运行时通过 render-compat.json 将已知原资源身份映射到对应变体。此目录因此同时是覆盖包输入与原生材质适配的选择契约。

## 约束

- 新增或更名 shader 时同时更新精确身份映射和打包收集范围；仅增加文件不能使运行时自动选用它。
- 不把生成 PCK 或外部原版游戏资源当作本目录源码。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| mobile_compat | `mobile_compat/` | 保持 uniform 接口的低采样变体与独立旧版 wiggle |
| 原生身份配置 | `render-compat.json` | 原路径、材质路径和内嵌代码身份到变体的映射 |
