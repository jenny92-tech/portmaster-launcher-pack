# 显示补丁构建

完整对应源码包为 `dist/wine-presentation-sources.tar.gz`，不含游戏资源。

Wine 来源为 `wine-mirror/wine` 的 `wine-10.0`，实际 commit 为 `b073859675060c9211fcbccfd90e4e87520dc2c2`。
原始源码归档 SHA-256 为 `71e4fef333852496d938a735ccbf45f090e23beb964172dd1defefa965b9956d`。
应用 `wine-handheld-startup.patch`，将 `wine_startup_card.h` 放入 `dlls/winewayland.drv/`。

Wine 编译在固定本地镜像 `sha256:85bc14fd04433e631c260cc120965d9fa4f1d865b62089f6a0bc595605cb782b` 内进行。
该镜像以现有 Debian bullseye 交叉工具链镜像为基础，新增依赖见同目录 Dockerfile。
构建容器无网络、只读根、capabilities 全部移除、no-new-privileges；仅源码只读、独立构建目录可写。
在容器的独立构建目录中执行：

```sh
/source/configure --enable-win64 --without-x --with-wayland --without-mingw --without-freetype
make -j4 dlls/winewayland.drv/winewayland.so
```

只将产出的 Unix 驱动放入固定 Wine 10 分发树的 `lib/wine/x86_64-unix/winewayland.so`；原有 Wine/Win32u/NTDLL 来自同一 Wine 10 ABI。
驱动最高引用 glibc 2.14，原生 ARM64 输入工具另需 glibc 2.29；这不代替目标固件实际加载验证。

WSI 来源 `GinKage/vulkan-wsi-layer` commit `40cfec09d0e2d42c5e1f2642cf4cba11e7008112`，源码归档 SHA-256 为
`43954274b528086371a42bf74accd9e2d8a83a9613fc0833b26f257d882246fc`。
依次应用原有 `wsi-ext-timestamps.patch` 和本目录 `wsi-first-frame.patch`。
从固定原始归档应用两份补丁后，须逐文件核对实际编译输入。

ARM64 WSI 构建使用已有固定工具链镜像 `sha256:f539f5cddea8a2fca41644cc981a0bcf6abb3a968ffdf943f568bbc2fed72984`，同样隔离。
CMake 工具链设置 Linux/aarch64、`aarch64-linux-gnu-gcc/g++`，查找根为 `/usr/aarch64-linux-gnu` 和明确提供的 ARM64 依赖根 `/deps/usr`。
`PKG_CONFIG_PATH` 使用 `/deps/usr/lib/aarch64-linux-gnu/pkgconfig:/deps/usr/share/pkgconfig`。
Vulkan Headers 和依赖包来源记录一同放入对应源码包；配置参数如下：

```sh
cmake -S /source -B /build/cmake -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/build/toolchain.cmake -DCMAKE_BUILD_TYPE=Release \
  -DVULKAN_CXX_INCLUDE=/headers/include \
  -DBUILD_WSI_X11=OFF -DBUILD_WSI_HEADLESS=OFF \
  -DBUILD_WSI_WAYLAND=ON -DBUILD_WSI_DISPLAY=OFF \
  -DSELECT_EXTERNAL_ALLOCATOR=dma_buf_heaps -DWSIALLOC_MEMORY_HEAP_NAME=system-uncached
cmake --build /build/cmake --parallel 2
```

Win64 全屏助手通过 Clang `-target x86_64-pc-windows-msvc -Os -ffreestanding -fno-stack-protector` 编译，
再以 `x86_64-w64-mingw32-ld --entry mainCRTStartup --subsystem windows --no-insert-timestamp` 链接，仅导入 Kernel32 的动态 API 入口。
源码和每个产物的实际 SHA-256 见 `runtime-sources.json`；打包器同时检查源文件、补丁和二进制。

私有启动环境另用 `src/scripts/build-bootstrap.py` 在电脑构建。设备启动只调用 `bootstrap.sh`，不调用系统 Python。
该环境的来源、独立授权和校验记录在 `bootstrap-sources.json` 及映像内的 `notices/`、Python 自带许可中。
