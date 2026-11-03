# Godot runtime inputs

This directory accepts externally built Godot engines and their matching managed
bindings. Engines are build outputs; maintained changes belong in a source
repository or the patches below, not in a disposable build directory.

## Fixed native Wayland/Mono source

The native Vulkan/Mono patch baseline is upstream
[Godot 928ee70231821228dc7b21b34008af7d5af1322a](https://github.com/godotengine/godot/tree/928ee70231821228dc7b21b34008af7d5af1322a).
Its local changes are preserved in the repository; apply them in this order to
a separate checkout of that exact revision:

| Patch | Purpose |
|---|---|
| [godot-928-vma-memory.patch](../../tools/csharp-godot-arm64-kit/godot-928-vma-memory.patch) | Optional VMA block sizing and bounded memory statistics |
| [godot-928-richtext-small-pool.patch](../../tools/csharp-godot-arm64-kit/godot-928-richtext-small-pool.patch) | RichTextLabel-only RID pool sizing |
| [godot-928-system-font-diag.patch](../../tools/csharp-godot-arm64-kit/godot-928-system-font-diag.patch) | Explicitly enabled system-font cache diagnostics |

Check each patch before applying it. The pinned toolchain, Mono glue and assembly
build procedure, fixtures and diagnostic boundaries are documented in
[MEMORY-PROFILING.md](../../tools/csharp-godot-arm64-kit/MEMORY-PROFILING.md).
This source and patch set can reconstruct the maintained engine changes without
retaining historical build trees, logs or candidate binaries. It does not promise
an identical old binary hash or reproduce undocumented PortMaster build inputs.

## Runtime variants and paired artifacts

The 928 patch baseline uses native Wayland; it does not add the custom SDL2
DisplayServer. SDL2/GLES development remains in the independent
[Godot fork, 4.5-arm64-sdl2](https://github.com/jenny92-tech/godot/tree/4.5-arm64-sdl2).
The two runtime variants require their own matched native/managed interfaces
and device validation. One is not a drop-in replacement for the other.

The stock assembly reads these explicitly supplied files:

| File | Consumer |
|---|---|
| `godot.linuxbsd.template_release.arm64.mono` | Copied as `godot.mono` |
| `GodotSharp.dll` | Copied into `data_sts2_linuxbsd_arm64/` |

Keep the engine and bindings from one compatible build together. Mixing unrelated
P/Invoke bindings and native exports can crash at startup. The reviewed Windows
game preparation also checks its exact Linux GodotSharp baseline; a new engine
build does not authorize replacing that input or bypassing its hash gate.

Resource conversion on the host uses **official stable Godot 4.5.1**, selected
explicitly or from PATH. The handheld's RC/custom runtime cannot replace that
asset-build tool. Supply tools and runtime artifacts under their own licenses.

## Verification boundary

Before using a rebuilt runtime, inspect its ELF dependencies and GLIBC symbol
requirements, verify the managed/native API pair, then separately check display,
controller input, text, gameplay, save and normal exit on the intended device.
This document records the source inputs and retained changes; it does not claim
a new build, binary audit, deployment or device acceptance.
