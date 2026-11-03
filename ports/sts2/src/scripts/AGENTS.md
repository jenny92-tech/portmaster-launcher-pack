# STS2 构建与部署

连接本移植源码、共享 _kit 与 dist/部署布局的构建入口。dist-port.sh 生成核心产物；make-overlay-pck.py 收集移动着色器；assemble-launcher-pack.sh 补齐运行时；deploy-to-device.sh 同步至指定设备。

## 约束

- 启动脚本名称从 manifest.json 读取，UI_ONLY 不触碰已有游戏负载。
- UI_ONLY 同步入口、封面和 port.json；入口改名时只清理带本端口标记的旧生成 SH 与同名封面。
- 完整、UI_ONLY 和运行时补齐打包在最终负载收集后调用共享 build_info.py，更新包构建身份和启动日志。
- 完整构建需要玩家提供的引用程序集和指定外部运行时；不分发游戏内容或受限 FMOD 运行库。
- 设备部署使用 rsync --delete，执行前必须明确目标和删除范围。
- SDL2 构建受设备 glibc 与 KMSDRM/ALSA 驱动集合约束，二进制与版本记录由对应构建流程维护。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 组件与许可清单 | `MANIFEST.md` | 完整装配布局、组件来源、玩家输入和分发边界 |
| assemble-launcher-pack.sh | `assemble-launcher-pack.sh` | 将核心启动器产物与可再分发 ARM64 运行时组合 |
| build_bundled_sdl.sh | `build_bundled_sdl.sh` | 构建仅供游戏阶段使用的低 glibc KMSDRM/ALSA SDL2 |
| deploy-to-device.sh | `deploy-to-device.sh` | 在明确指定 SSH 目标后构建并部署 STS2 产物 |
| dist-port.sh | `dist-port.sh` | 构建核心兼容 DLL、覆盖包与可部署启动器 |
| make-overlay-pck.py | `make-overlay-pck.py` | 按 Godot PCK 目录与对齐规则打包移动端替代着色器与共享 Godot 性能浮层 |
| 官方运行时资源补丁 | `make-official-runtime-overlay.py` | 打包原生兼容资源与共享浮层、缩短菜单粒子预模拟；可显式按精确身份生成流畅档轻量特效场景，并输出来源及修改报告 |
| 可选纹理诊断包 | `make-texture-diagnostic-pck.py` | 打包独立新路径的只读纹理诊断场景，供显式挂载使用 |
| VRAM 恢复身份 | `vram_texture_specs.json` | 原版有效ASTC映射、新版同源散列、纹理角色和逐项排除原因，不含原始图像 |
| VFX 目录生成 | `build-vfx-inventory.py` | 从指定来源的私有扫描报告生成身份分类与湍流依赖元数据 |
| Windows 启动资源 | `windows_runtime_resources.py` | 保留原配置并精准调整 ARM64 映射、原生扩展和自加载配置 |
| 全包材质与 shader 规则 | `global_material_policy.py` | 对可识别文本资源按类型或代码结构降低粒子湍流及视觉采样，报告每项变化和未处理边界 |
| 特效静态目录 | `simple_effects_inventory.json` | 对指定原版 PCK 的全部 VFX 场景保存身份、静态类别与待审原因；实际转换须与构建清单核对 |
| 特效身份清单 | `simple_effects_specs.py` | 按已审计的通用粒子根与调用契约记录精确场景身份、生命周期和轻量视觉 |
| 粒子湍流身份 | `turbulence_specs.json` | 已审计 VFX 场景粒子材质身份及依赖闭包，供旧输入模式和报告使用 |
