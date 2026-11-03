# godot fork build artifact

The godot 4.5 mono linuxbsd arm64 engine binary used to run the game, plus
its matching GodotSharp.dll.

## Contents

| File | Size | Description |
|---|---|---|
| `godot.linuxbsd.template_release.arm64.mono` | 62 MB | Engine binary, renamed to `godot.mono` on deploy |
| `GodotSharp.dll` | 5.6 MB | The C# bindings it must be paired with (from the same build) |

## Source

- **Repo**: <https://github.com/jenny92-tech/godot>
- **Branch**: `4.5-arm64-sdl2` (supersedes `linuxbsd-sdl2`; the SDL2
  DisplayServer is now SDL-only — the self-managed KMS/GBM/EGL path was
  removed, so the binary no longer links `libdrm`/`libgbm`. CI hard-fails if
  either shows up in DT_NEEDED.)
- **CI Workflow**: `.github/workflows/build-sdl2-arm64.yml` ("🛠 Build linuxbsd SDL2 arm64")
- **This build**: local Docker build (2026-07-24, image `godot-sdl2-builder`,
  glibc ≤ 2.31) from uncommitted `4.5-arm64-sdl2` working tree — first
  SDL-only build; DT_NEEDED verified free of libgbm/libdrm/libEGL/libGLESv2
- **Artifact**: `godot-linuxbsd-sdl2-mono-arm64`

## Refresh (option A: local Docker build)

```bash
docker run --rm \
  -v <godot-repo>:/src \
  -v <logs-dir>:/logs \
  -v godot-dotnet:/dotnet \
  godot-sdl2-builder:latest bash /logs/build-sdl2-mono.sh
# build-sdl2-mono.sh mirrors the CI mono variant (scons flags, DT_NEEDED hard
# check, .NET 8, mono glue, GodotSharp.dll). Then:
cp <godot-repo>/bin/godot.linuxbsd.template_release.arm64.mono ./
cp <godot-repo>/bin/GodotSharp/Api/Release/GodotSharp.dll ./
```

## Refresh (option B: pull a new CI build)

```bash
# trigger the workflow (manual dispatch)
gh workflow run "🛠 Build linuxbsd SDL2 arm64" -R jenny92-tech/godot --ref 4.5-arm64-sdl2 -f variants=mono

# wait ~20 min, then download
gh run list -R jenny92-tech/godot --workflow "🛠 Build linuxbsd SDL2 arm64" --limit 1
RUN=<run-id>
gh run download $RUN -R jenny92-tech/godot --dir /tmp/godot-fresh
cp /tmp/godot-fresh/godot-linuxbsd-sdl2-mono-arm64/__w/godot/godot/bin/godot.linuxbsd.template_release.arm64.mono ./
cp /tmp/godot-fresh/godot-linuxbsd-sdl2-mono-arm64/__w/godot/godot/bin/GodotSharp/Api/Release/GodotSharp.dll ./
# sanity: must print nothing
objdump -p godot.linuxbsd.template_release.arm64.mono | grep -E "libgbm|libdrm"
```

> ⚠️ **The two files must be paired**: the C# bindings' P/Invoke signatures
> must match the native functions exposed by godot.mono. Mixing them (e.g. an
> old godot.mono with a new GodotSharp.dll) SEGVs immediately.

## Deploy to device

```
godot.mono                                                # renamed from godot.linuxbsd.template_release.arm64.mono
data_sts2_linuxbsd_arm64/GodotSharp.dll                   # used by the game
runtimes/sdl2_fixed/godot.mono                            # source for switch_runtime.sh
runtimes/sdl2_fixed/GodotSharp.dll                        # same
```

## Binaries are NOT distributed in this repo

The engine binary + GodotSharp.dll (62 MB / 5.6 MB) are not committed to git
(size). godot is MIT-licensed — just build your own linuxbsd arm64 mono
binaries per the source above.
