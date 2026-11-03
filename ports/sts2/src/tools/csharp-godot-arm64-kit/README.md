# csharp-godot-arm64-kit · C# Godot → arm64 handheld porting toolkit

Diagnostic + patching scripts for moving **C#/.NET Godot games** (Windows x64 export)
to **aarch64 Linux handhelds** (MiniLoong / RK3566 class).

All inputs are provided explicitly. Extracted game configurations and patch
payloads stay in private build storage and are not included in this toolkit.

## Pipeline (tool order)

| Step | Tool | When / Why | Usage |
|---|---|---|---|
| ① After assembling target-arch .NET runtime | **`rewrite_deps_json.py`** | Cross-RID rewrite of `deps.json`; otherwise `Could not resolve CoreCLR path` | `python3 rewrite_deps_json.py <DATA_dir>` |
| ② Diagnose .NET load failures | **`peflags.py`** | Inspect PE machine / PE32+ / CLI flags / R2R status | `python3 peflags.py a.dll b.dll …` |
| ② Confirm types exist | **`clrmeta.py`** | Parse ECMA-335 metadata to verify a type/method is really in the assembly | `python3 clrmeta.py app.dll` |
| ③ Fix x64-marked assemblies | **`patch_pe_machine.py`** | Pure-IL assemblies with `<PlatformTarget>x64` rejected by arm64 coreclr: flip PE machine `AMD64→ARM64` (2 bytes each) | `python3 patch_pe_machine.py <DATA_dir> [--dry]` |
| ④ In-place pck file patch | **`apply_pck_blob_patch.py`** | Replace a file with explicitly supplied same-length data and original-content metadata; update directory MD5 | `python3 apply_pck_blob_patch.py <pck> <meta.json> <blob>` |
| ⑤ Build native arm64 extensions | **`ci/*.yml`** | fmod / spine GDExtensions with no linux-arm64 release: fork upstream + GitHub arm64 runner | See CI section below |

## Memory diagnostics

[MEMORY-PROFILING.md](MEMORY-PROFILING.md) covers the pinned Godot/VMA build,
RichTextLabel and system-font fixtures, private heaptrack collection and offline
module summaries. These tools remain separate from normal launcher builds.

## CI workflows (`ci/`)

- `fmod_build-linux-arm64.yml` → targets a fork of `utopia-rise/fmod-gdextension` (branch `master`).
  Needs repo secrets `FMODUSER`/`FMODPASS` (free FMOD account). Self-contained.
  Produces `libGodotFmod.linux.*.arm64.so` (GLIBC ≤ 2.17) + FMOD runtime `libfmod.so.14.6` / `libfmodstudio.so.14.6`.
- `spine_build-linux-arm64.yml` → targets a fork of `EsotericSoftware/spine-runtimes` (branch must match skeleton version,
  here `4.2`). No secrets needed. Produces `libspine_godot.linux.*.arm64.so` (GLIBC ≤ 2.29).
- Both use `ubuntu-24.04-arm` runner **+ `container: ubuntu:20.04`** (critical: container glibc 2.31 covers
  typical PortMaster handhelds at 2.31–2.33). Each ends with `objdump -T *.so | grep GLIBC_` self-check.
  godot-cpp pinned to `4.5` (≤ game Godot version).

## Patch inputs

Metadata must bind the blob offset, size, directory MD5 position and original/new
content hashes to the exact input pack. Generate it from the player's own input;
do not reuse offsets from another build. The FMOD-specific wrapper additionally
requires an explicit patch directory. Host regressions use synthetic bytes.

## Intentionally excluded

- FMOD closed-source runtime `libfmod*.so` — not redistributable in this repo; get from the fmod fork CI.
- Game .NET assemblies / pck — copyright; player provides.
- Prebuilt `.so` / data dirs — rebuildable from forks (CI) + the scripts above.
