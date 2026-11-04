# STS2 构建与部署

共享 dist 调度在此构建兼容 DLL 和资源覆盖，assemble-launcher-pack.sh 再补齐可分发运行时。资源构建器分别处理正式覆盖、官方 runtime 适配和独立诊断包；deploy-to-device.sh 是另一个带删除同步语义的显式设备入口。

## 约束

- 入口名来自 manifest；UI_ONLY 只同步入口、封面与 port.json，不改游戏负载。改名时仅清理带本端口标记的旧生成 SH 和同名封面。
- 完整、UI_ONLY 和运行时补齐打包在最终负载收集后调用共享 build_info.py，更新包构建身份和启动日志。
- 完整构建需要玩家提供的引用程序集和指定外部运行时；不分发游戏内容或受限 FMOD 运行库。
- Steam companion 默认从端口自己的 tools/steam_mock 产物读取，也可显式指定；不依赖 Bogodroid 知识库的旧源码路径。
- 设备部署使用 rsync --delete，执行前必须明确目标和删除范围。
- SDL2 构建受设备 glibc 与 KMSDRM/ALSA 驱动集合约束，二进制与版本记录由对应构建流程维护。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 组件与许可清单 | `MANIFEST.md` | 完整装配布局、组件来源、玩家输入和分发边界 |
| assemble-launcher-pack.sh | `assemble-launcher-pack.sh` | 把核心产物与可再分发 ARM64 runtime 装配 |
| build_bundled_sdl.sh | `build_bundled_sdl.sh` | 构建仅供游戏阶段使用的低 glibc KMSDRM/ALSA SDL2 |
| deploy-to-device.sh | `deploy-to-device.sh` | 在明确指定 SSH 目标后构建并部署 STS2 产物 |
| dist-port.sh | `dist-port.sh` | 核心 DLL、覆盖资源及启动器负载 |
| make-overlay-pck.py | `make-overlay-pck.py` | 按 PCK 对齐约定收集 shader 和共享浮层 |
| 官方运行时资源补丁 | `make-official-runtime-overlay.py` | 官方资源适配、轻量场景及逐项来源报告 |
| 可选纹理诊断包 | `make-texture-diagnostic-pck.py` | 仅含独立诊断路径的小 PCK |
| VRAM 恢复身份 | `vram_texture_specs.json` | 原版有效ASTC映射、新版同源散列、纹理角色和逐项排除原因，不含原始图像 |
| VFX 目录生成 | `build-vfx-inventory.py` | 从指定来源的私有扫描报告生成身份分类与湍流依赖元数据 |
| Windows 启动资源 | `windows_runtime_resources.py` | 原配置保留与 ARM64 扩展/自加载重绑定 |
| 全包材质与 shader 规则 | `global_material_policy.py` | 按文本结构转换材质/shader并报告未处理边界 |
| 特效静态目录 | `simple_effects_inventory.json` | 对指定原版 PCK 的全部 VFX 场景保存身份、静态类别与待审原因；实际转换须与构建清单核对 |
| 特效身份清单 | `simple_effects_specs.py` | 按已审计的通用粒子根与调用契约记录精确场景身份、生命周期和轻量视觉 |
| 粒子湍流身份 | `turbulence_specs.json` | 已审计 VFX 场景粒子材质身份及依赖闭包，供旧输入模式和报告使用 |
