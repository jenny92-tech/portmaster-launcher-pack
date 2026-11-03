# STS2 着色器覆盖资源

连接兼容补丁路径映射与 Godot 资源覆盖包的资源父目录。mobile_compat 内的 gdshader 被收集到 res://shaders/mobile_compat，再由运行时补丁按精确身份选择。render-compat.json 是官方运行时原生适配的身份配置。

## 约束

- 新增资源时同时核对运行时映射和打包收集范围。
- 不把生成 PCK 或外部原版游戏资源当作本目录源码。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| mobile_compat | `mobile_compat/` | 保留材质语义的有界低采样着色器变体及旧版 wiggle |
| 原生身份配置 | `render-compat.json` | 上游固定版本的路径、材质和内嵌代码身份映射 |
