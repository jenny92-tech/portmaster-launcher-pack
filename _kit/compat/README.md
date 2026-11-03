# 共享兼容产物

这里保存难以直接下载或带有本项目适配补丁的小型原生产物，供构建时复用。
当前只有 [ARM64 Wayland Vulkan WSI](vulkan-wsi-arm64-wayland/README.md) 一项：
库为 352,096 字节，源码版本、补丁、许可、ABI 和接入方式随库保存。
完整定制 Godot 不属于此归档，运行时接入由对应端口单独验证。

## 每个产物都要回答的问题

| 问题 | 记录位置 |
|---|---|
| 为了解决什么需求、处于哪一层、连接谁 | `README.md` 与 `artifact.json.role` |
| CPU、系统 ABI、动态库、图形/内核接口要求 | `artifact.json.requires` 与实际 ELF 检查记录 |
| 来自哪里、哪份源码和补丁、如何构建 | `artifact.json.source`、补丁文件和原构建记录 |
| 哪些目标验证过、验证到什么程度 | `artifact.json.validation` |
| 怎么选清单、启用、禁用及复用 | `README.md` 与 `artifact.json.integration` |
| 什么情况才需要重编 | `artifact.json.rebuild_when` / `no_rebuild_for` |
| 是否同一个文件、有没有被改过 | 实际字节数、SHA256、文件闭集和 LFS 对象身份 |

## 验证与保存

```sh
python3 _kit/compat/verify.py
```

校验只读取归档，不执行动态库或启动任何游戏。根 `.gitattributes` 将这里的 `.so`
交给 Git LFS，JSON、补丁、说明和许可仍用普通 Git。提交二进制前须保留其完整许可
与来源；发布/推送是独立操作，不因归档自动发生。

若克隆后只拿到 LFS 指针，需要恢复对应对象，例如：

```sh
git lfs pull --include='_kit/compat/vulkan-wsi-arm64-wayland/*.so'
```

## 复用规则

一份 ELF 可以服务多个满足相同 ABI 与图形接口要求的设备。设备名称或 IP 不构成
重编理由；不同加载清单也可复用同一 ELF。引擎、固件、驱动组合仍需由启动层选择
并完成预检和实机验证，不能把一个技术栈的验收结果直接赋给另一个。

构建时只复制当前游戏需要的库和匹配清单到应用私有 runtime。归档不依赖 `.cache`，
不替换系统 ICD/GPU 驱动，也不要求每台设备安装编译器。
