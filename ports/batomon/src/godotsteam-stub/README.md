# Batomon GodotSteam Stub

离线版 GodotSteam GDExtension，用于 ARM64 开源掌机（无需 Steam 客户端）。

## 原理

游戏在标题页检查 `Steam.getSteamID() != 0` 来判断是否有 Steam 用户登录。
这个 stub 把关键方法硬编码返回"已登录"的值，骗过游戏直接进主菜单。

| 方法 | 返回值 |
|------|--------|
| `steamInit()` | `true` |
| `steamInitEx()` | `{"status": 1}` |
| `loggedOn()` | `true` |
| `isSteamRunning()` | `true` |
| `getSteamID()` | 假 SteamID64 |
| `getPersonaName()` | `"Player"` |
| 其他所有方法 | null/0/false（安全默认值） |

## 源码结构

```
src/godotsteam-stub/
├── SConstruct          # scons 编译脚本
├── generate-bindings.py # 从 GodotSteam 文档生成方法绑定
├── src/
│   ├── steam_stub.h
│   ├── steam_stub.cpp          # ★ 核心逻辑在这里
│   ├── steam_stub_bindings.gen.inc  # 自动生成的方法桩
│   ├── register_types.h
│   └── register_types.cpp
└── godot-cpp/          # Godot C++ 绑定库（git submodule）
```

## 编译

前置条件：Docker 镜像 `godot-sdl2-builder:latest`（内含 aarch64 交叉编译链 + scons）。

```bash
cd ports/batomon/src/godotsteam-stub

# 首次需要克隆 godot-cpp（Godot 4.3 版本）
git clone --depth 1 --branch 4.3 https://github.com/godotengine/godot-cpp.git godot-cpp

# 编译
docker run --rm \
  -v "$PWD:/work" -w /work \
  godot-sdl2-builder:latest \
  bash -c "
    export CC=aarch64-linux-gnu-gcc
    export CXX=aarch64-linux-gnu-g++
    scons platform=linux arch=arm64 target=template_release \
      target_path=bin target_name=godotsteam -j\$(nproc)
  "
```

产物：`bin/libgodotsteam.linux.template_release.arm64.so`

## 目录规划与部署

### 源码层（不部署）
```
ports/batomon/src/
├── godotsteam-stub/   # stub 源码 + 编译脚本
├── scripts/
│   ├── dist-port.sh           # 打包 dist/ 目录
│   └── prepare-batomon-pck.py # PCK 解密 + 修补
├── launcher.sh                # 启动脚本
├── launcher-offline.sh
└── bin/                       # Steam 登录辅助脚本（离线不需要）
```

### 编译输出层 = dist/（直接放到设备上）
```
ports/batomon/dist/
├── Batomon Showdown.sh        # 启动脚本
├── godot.mono                 # Godot 4 运行时
├── libsteam_api64.so          # C 层 Steam API stub
├── addons/godotsteam/linuxarm64/
│   └── libgodotsteam.linux.template_release.arm64.so  # ★ stub
└── gamedata/
    └── batomon_showdown.pck   # 游戏数据（已解密 + 修补）
```

### 设备上的布局
```
/mnt/SDCARD/Data/ports/batomon/
├── Batomon Showdown.sh        # PortMaster 入口
├── godot.mono
├── libsteam_api64.so
├── addons/godotsteam/linuxarm64/
│   └── libgodotsteam.linux.template_release.arm64.so
└── gamedata/
    └── batomon_showdown.pck
```

## SO 文件位置说明

**不能随便放。** PCK 里的 `.gdextension` 配置文件指定了精确路径：

```
linux.release.arm64 = "res://addons/godotsteam/linuxarm64/libgodotsteam.linux.template_release.arm64.so"
```

`res://` 是 Godot 的资源根目录，等于 `godot.mono` 所在的目录。
所以设备上**必须**放在 `godot.mono` 同级的 `addons/godotsteam/linuxarm64/` 下。

## 打包到 dist

`dist-port.sh` 通过环境变量 `BATOMON_GODOTSTEAM_ARM64` 指定 stub 路径：

```bash
BATOMON_GODOTSTEAM_ARM64=./src/godotsteam-stub/bin/libgodotsteam.linux.template_release.arm64.so \
  ./src/scripts/dist-port.sh
```

## 修改逻辑后如何更新设备

```bash
# 1. 编译
cd ports/batomon/src/godotsteam-stub
docker run --rm -v "$PWD:/work" -w /work godot-sdl2-builder:latest \
  bash -c "export CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++; scons platform=linux arch=arm64 target=template_release target_path=bin target_name=godotsteam -j\$(nproc)"

# 2. 推到设备
scp bin/libgodotsteam.linux.template_release.arm64.so \
  root@<设备IP>:/mnt/SDCARD/Data/ports/batomon/addons/godotsteam/linuxarm64/
```
