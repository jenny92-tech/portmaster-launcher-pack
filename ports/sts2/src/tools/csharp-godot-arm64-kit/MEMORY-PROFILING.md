# Godot 内存分析

本目录保留可复现的引擎补丁、隔离入口生成器与离线汇总工具。诊断产物不进入正式游戏包，
不会自动替换已安装引擎。入口生成器绑定已审输入，身份不符时应停止，不能仅更新摘要绕过门禁。

## 指标与对照

| 指标 | 解释边界 |
|---|---|
| `/proc/PID/status` VmRSS、smaps RSS、PSS | 分别记录，不相加；驱动映射与内核统计方式可能造成差异 |
| HUD 纹理估算 | 已识别格式的名义数据量，不是精确 GPU 分配，也不能加到 RSS |
| VMA block / allocation bytes | 块内余量不是等量 RSS 或可直接回收字节；heap 与 type 汇总不能相加 |
| .NET GC 计数 | 不包括全部运行时原生分配或 Godot 资源；不以差额推算显存 |
| heaptrack live / cumulative | 存活量与分配总流量不同；不覆盖所有 mmap、GPU、托管对象及专用分配器 |

比较时固定引擎、资源、语言、分辨率、场景、阶段和开关，记录进程与局随机性。
诊断日志、栈展开、文件 IO 和 profiler 本身都会扰动内存与帧率。
资源文件大小、一次采样或不同进程之间的差值不能作为固定收益保证。

`collect_memory_snapshot.py` 和 `collect_runtime_counters.py` 位于上级工具目录，要求
显式设备目标、PID 与 starttime；前者还绑定构建和阶段。它们采集聚合数据，不导出堆内容。
计数器工具绑定 Microsoft 签名的 dotnet-counters 9.0.661903，需按脚本要求准备私有工具目录。

## 固定 Godot 构建

实验补丁基于 [Godot](https://github.com/godotengine/godot) 提交
`928ee70231821228dc7b21b34008af7d5af1322a`。使用独立源码树和
`Dockerfile.vma-trial` 固定的 Ubuntu 20.04 ARM64 镜像，保存实际系统包清单。
该构建不宣称复刻 PortMaster 未公开的全部参数或补丁。

外部工具需独立准备并校验：

| 工具 | 固定版本 | 摘要 |
|---|---|---|
| Microsoft Linux ARM64 SDK | 8.0.427 | SHA-512 `2b851de08e94922b382d1d2754df112cd167f6e9b6f3d15d2cfe143fded1d5b05d6b196b545941d22c97db62bb426d71a4fe6e131a92e482c6ea1a7337ffedab` |
| SCons wheel | 4.7.0 | SHA-256 `93308e564966760a63a4c1e016b2cc15d07bb40db67b1c907732da0b9e9f8959` |

容器只挂载实验目录，编译阶段断网。以下命令在固定源码工作目录运行，工具路径按隔离环境设置：

```sh
scons platform=linuxbsd arch=arm64 target=editor module_mono_enabled=yes x11=yes wayland=yes udev=yes optimize=size lto=none debug_symbols=no -j4
bin/godot.linuxbsd.editor.arm64.mono --headless --generate-mono-glue modules/mono/glue
git apply --check /kit/godot-928-vma-memory.patch
git apply /kit/godot-928-vma-memory.patch
scons platform=linuxbsd arch=arm64 target=template_release module_mono_enabled=yes x11=yes wayland=yes udev=yes production=yes lto=full debug_symbols=no -j4
./modules/mono/build_scripts/build_assemblies.py --godot-output-dir=./bin --godot-platform=linuxbsd
```

核对实际 editor 文件名、ELF 依赖、GLIBC 符号要求和匹配的 managed assemblies，保存产物摘要。
构建通过后仍须验证 GodotSharp API、显示、手柄、首战、首攻与正常退出，再评估替换运行时。

## 引擎补丁与入口

- `godot-928-vma-memory.patch` 增加首选大堆块设置 `preferred_large_heap_block_size_mb`，
  只接受 0/32/64；0 保留 VMA 默认选择。独立的 `log_memory_statistics` 默认关闭，
  开启后最多每十秒输出聚合统计。`VMA_CONFIG` 的 `auto_default=true` 不表示实际块大小为零。
- `vma_trial_entry.py` 位于上级目录，核验入口、引擎及独立运行目录后生成非菜单实验脚本。
  配置必须在 rendering device 创建前生效；使用同引擎的 0/32/64 组和相同采样开关作对照。
- `godot-928-richtext-small-pool.patch` 将 RichTextLabel 单类 RID 分块目标改为 4096 字节，
  不修改全局 RID 策略。`richtext_pool_fixture.gd` 验证多轮长文本、清理和重建；
  对照/候选均应正常退出并输出 12 行 PASS 与 `RICH_TEXT_FIXTURE_OK`。块容量减少不等于 RSS 收益。
- `godot-928-system-font-diag.patch` 叠加于 VMA 与 RichTextLabel 补丁，只有
  `SLL_SYSTEM_FONT_DIAG=1` 才记录字体缓存 miss 元数据。`system_font_diag_fixture.gd`
  验证关闭时与对照一致、开启时固定字符的 miss。累计 miss 次数和读取逻辑字节不是当前
  缓存占用或唯一文件数；日志展示应转义控制字符。该诊断不读取或输出字体内容。

`SLL_HEAP_TRIM=1` 是独立且默认关闭的游戏侧试验，实现在
`src/STS2LinuxLauncher/Patches/NativeHeapTrim.cs`（相对端口根目录）。它仅在已核验
glibc ABI 的 Linux 进程内于战斗准备回调尝试一次 `malloc_trim(0)`，不释放游戏资源、
清缓存或强制 GC。`release_hint` 是释放过页的布尔提示，不是字节数；不要与 heaptrack 同时测量。

## heaptrack 采集边界

使用 [heaptrack v1.3.0](https://github.com/KDE/heaptrack/tree/994301d7388960148b2dd2227b62b5a78945d7a7)
的 tracker/interpreter。旧 focal 1.1 包在隔离 fixture 的退出路径崩溃，不应作为游戏采集器。
在独立 Ubuntu 20.04 ARM64 容器准备 CMake、Boost 1.71 与 libunwind 后，断网构建：

```sh
cmake -S /work/heaptrack-1.3 -B /work/heaptrack-build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DHEAPTRACK_BUILD_GUI=OFF -DHEAPTRACK_BUILD_PRINT=OFF -DHEAPTRACK_BUILD_INTERPRET=ON -DHEAPTRACK_BUILD_TRACK=ON -DBUILD_TESTING=OFF
cmake --build /work/heaptrack-build --parallel 4
```

这是诊断器构建，不是正式交付配置。`vma_heap_profile_entry.py` 绑定已审 preload、
libunwind 和私有入口的完整 SHA；自建的不同二进制不能直接使用其固定配置。
先用无玩家数据的合成 fixture 验证依赖、已知分配、正常退出和完整尾部记录。

仅在新启动的隔离进程最后一次游戏 exec 注入 preload，不附加现有游戏或向其他辅助程序
注入。使用独占 0700 目录、全新输出文件和 `umask 077`。trace 会包含完整 argv、模块路径、
地址、时间及系统页信息，原始和解释后的文件都应保持私有。采集不提供安全的硬存储上限；
不能靠截断 FIFO 或文件大小信号停止采集，应预留空间并通过正常退出验证收尾。

## 离线汇总

同版 interpreter 需要与记录路径匹配的模块 ELF；缺少符号时不能猜测内部函数。
Build ID 不同的符号副本不能直接当成同一二进制，须有独立的代码地址对应证据。
v1.3 interpreter 不支持新版 `--sysroot`，需要在隔离容器准备精确路径。

将 raw 解释为格式 3 文本后：

```sh
python3 heaptrack_modules.py /PRIVATE/interpreted.txt --at-ms 10000
python3 test_heaptrack_modules.py
```

模块按最靠近分配处的首个非通用运行库栈帧归属，不代表最终资源所有者。
输出区分累计流量、采样时存活量、各模块峰值和全局峰值时的模块量；各模块峰值不能相加。
`--at-ms` 取第一个不早于目标的时间标记，事件时间精度受 trace 限制；截取分析仍需调用方
单独核验原始 trace 正常结束。测试覆盖合成分配/释放、峰值、时间和非法/截断记录。
