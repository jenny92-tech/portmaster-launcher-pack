# Godot PCK texture tools

Convert desktop BPTC/S3TC textures to mobile GPU formats such as ASTC/ETC2.
This avoids Godot's RGBA CPU fallback consuming excessive memory on handhelds.
Scripts and ownership are listed in [AGENTS.md](AGENTS.md).

## STS2 workflow

From this directory:

```sh
patches/sts2/build.sh /path/to/SlayTheSpire2.pck
# Output: work/sts2/output.pck
```

The original PCK remains unchanged. The build may clear its recovered/overlay
working directories; verify inputs and available scratch space before running.

1. `extract.sh` recovers into `work/<game>/recovered/` using GDRE Tools.
2. `patch_project.py` and `force_vram_compress.py` select mobile texture compression.
3. `reimport.sh` runs Godot import to regenerate device textures.
4. `strip_non_astc.py` removes other compressed variants.
5. The game-specific `apply.sh` adds extension mappings/stubs and edits project configuration.
6. Build a merged overlay of textures, import records, settings and static overrides.
7. `apply_overlay.py` uses GDRE `--pck-patch` against the original PCK.

Patching preserves original Spine/FMOD binaries and compiled scripts that a host
editor cannot regenerate. `repack.sh` instead creates a PCK from the recovered
tree; it is a separate operation, not an interchangeable final step.

## Dependencies

- GDRE Tools under `bin/gdre_tools` on Linux, or
  `bin/Godot RE Tools.app/Contents/MacOS/Godot RE Tools` on macOS.
- A matching Godot Mono editor. `reimport.sh` accepts the executable via `GODOT`;
  otherwise it uses the platform default encoded in the script.
- Shell, Python 3 with Pillow, and enough space for recovered resources, imports and output.

External binaries and `work/` are ignored local inputs, not repository source.
Use only player-owned game files; do not redistribute recovered projects,
modified imports or game PCKs.

## Another game

Create its own `patches/<game>/` orchestration and overlay, adapting `apply.sh`
to its project layout. Keep extract/import/texture operations game-independent.
Build-specific extension metadata and patches must be rederived and verified.
See the [STS2 patch description](patches/sts2/README.md) for the current example.

### Experimental private half-resolution overlay

`low_texture_overlay.py` builds a **separate** PCK from a player-supplied Godot
4.5.1 PCK and a private JSON report. It retains each GST2 logical size and
flags, and halves the encoded image dimensions (minimum one pixel). It uses
existing ASTC and WebP mip levels where available; other ASTC and WebP images are
processed with the official Godot CPU image codecs. Non-block-aligned ASTC
images are padded by extending their edges, without changing the recorded
half-size dimensions. WebP is saved losslessly. The original PCK is untouched.

```sh
python3 ports/sts2/src/tools/godot_pck/low_texture_overlay.py \
  --base /private/SlayTheSpire2.pck --godot /path/to/official-godot-4.5.1 \
  --cache /private/low-texture-cache --output /private/texture.pck \
  --report /private/texture-report.json
```

Keep the PCK, report, and cache private: they contain or identify game assets.
The build verifies source entry MD5s, records source and output PCK SHA-256
digests and each texture's source/output dimensions and directory hashes, checks cached results
by content hash, and verifies the completed overlay directory and data before
publication. Unknown formats, flags, incomplete mip chains, corrupt files,
conflicting import mappings, or missing texture source mappings stop the build. The report
identifies resources mapped through the exact import or through a sibling with
the same imported basename and 128-bit source-path hash. JSON byte totals
describe files, not RSS or measured GPU allocation. Run the same command to resume cached conversions.

Conservative exclusions are reported per texture: font/glyph and bitmap-font
directories, LUT, normal/data and explicitly marked normal maps, HDR RGBAH
data, and tiny mip chains or 1x1 images. Assets alongside Spine atlases or
with Spine names are also retained by default. Once the native Spine loader
has been verified to obtain page dimensions from `Texture2D.get_width()` and
`get_height()`, pass `--verified-spine-loader` to include them. The report
counts all candidate Spine-related pages and neighboring textures separately;
that directory-based count is not a precise count of character pages. These
heuristics are not proof that every data or Spine texture is classified. A
single Godot process handles up to 512 images per batch and each
completed result is saved immediately, allowing interrupted batches to resume.
The stock headless Godot fixture checks logical and atlas sizes
and CPU decoding; it cannot verify target GPU rendering or measure memory.

The private Vulkan trial can stream the original PCK and audited overlay into
an independent main PCK with `merge_texture_pck.py --source ORIGINAL --overlay
OVERLAY --report REPORT --output-dir PRIVATE_DIR`. It checks both input hashes,
the reported texture set and every entry MD5, then verifies the resulting PCK
and writes a sidecar. The trial chooses that merged PCK before the main scene
loads; removing its active selector restores the original. Startup checks the
installed source and merged sizes and modification times rather than hashing
large PCKs again, so same-size changes with unchanged times are not detected.
Full-PCK conversion and representative stock Godot CPU samples have been
checked locally. Target GPU rendering and actual memory savings remain untested.


## Read-only VFX inventory

Run this after a game update to rescan the supplied PCK without extracting or
executing game scripts. Choose a fresh private output directory on each run;
the two output files must not already exist.

```sh
python3 ports/sts2/src/tools/godot_pck/scan_vfx_catalog.py \
  --base /private/SlayTheSpire2.pck --output-dir /private/vfx-audit-new
```

The JSON inventories every `scenes/vfx/**/*.tscn`, with source SHA-256, root
and node properties, serialized instance overrides, recursive external text
resources, source hashes, particle material fields, shader flags, and
path-based category guesses. It also lists related combat/UI scene paths.
The Chinese summary and JSON record the source PCK SHA-256, scanner and reader
source hashes, and configuration. PCK entries are checked against their MD5;
unsupported pack formats, malformed text, and missing scene roots fail closed.
The scanner never alters its input or overwrites existing output files. Outputs
contain game resource descriptions, so keep them private.

For low-memory handheld review, GPU particles, turbulence, screen sampling and
VisualShader are leads for investigation because they may increase shader or
rendering work; they do not prove a stall. Counts are unique source definitions
in the recursive closure, not runtime instance counts or timings. Serialized
properties are read as text; multiline property continuations, implicit engine
defaults, relative/UID shader includes and dynamically loaded resources may
require additional inspection. Script types and node contracts require C#/caller
audits before any replacement; the inventory cannot prove that a scriptless
scene is removable. Preserve damage numbers, targeting controls and status
indicators. This scan does not run the game or benchmark device performance.

### Read-only shader and material inventory

```sh
python3 ports/sts2/src/tools/godot_pck/scan_shader_features.py \
  --base /private/SlayTheSpire2.pck --output-dir /private/new-shader-audit
```

The output directory must be private and the JSON report must not already exist.
The scan records source hashes, resource identities, typed feature flags, configured
identity matches, local resource references, remap/import edges, and potential
reverse scene dependencies. It does not export shader code or change the PCK.
Configured identity matches are not proof that a runtime replacement is applied;
VisualShader generated code, binary resources, dynamic scripts and implicit engine
defaults require separate inspection. Shader lexical call-site counts and graph-node
counts are indicators, not measured execution counts or performance. A closure is
a file-level static over-approximation and can miss dynamically loaded resources.
Keep all reports private because paths and metadata identify game assets.
# 玩家 Windows 自解压资源包的离线检查

本流程把用户提供的 RAR5 自解压 exe 当作数据，不执行 exe、SFX 脚本或提取出的游戏、DLL。仅适用于本机 macOS、已安装的 7-Zip，以及手动准备的官方 **UnRAR 7.23 macOS ARM64**。官方固定包为 <https://www.rarlab.com/rar/rarmacos-arm-723.tar.gz>，SHA-256 `68b393c000758d477fde43c955ff7542f12f76f3f5e87cdda923152fc791bd4d`；包内 `rar/unrar` 二进制 SHA-256 `99720d63484b8db77db43477db095f198d52b34515938d4ee7b165c59fa1cbe9`。二进制本身是 ad-hoc 签名，固定摘要记录本次获取的文件，不代替厂商签名。脚本不下载或安装工具，游戏数据和工具二进制不进入源码。

先自行只读核对输入摘要，指定尚不存在、空间充足的私人输出目录：

```sh
shasum -a 256 /PRIVATE/SlayTheSpire2-SFX.exe
python3 ports/sts2/src/tools/godot_pck/extract_windows_sfx.py \
  --source /PRIVATE/SlayTheSpire2-SFX.exe --source-sha256 SOURCE_SHA256 \
  --unrar /PRIVATE/unrar-7.23 --seven /opt/homebrew/bin/7zz \
  --output-dir /PRIVATE/new-extraction
python3 ports/sts2/src/tools/godot_pck/compare_pck_inventory.py \
  --left-pck /PRIVATE/new-extraction/files/SlayTheSpire2.pck \
  --right-pck /PRIVATE/current/SlayTheSpire2.pck --output /PRIVATE/comparison.json
```

示例 PCK 路径请按实际解压层级替换。比较脚本也可传 `--left-dll`、`--right-dll`、`--release-info`、`--deps`；包内版本信息只是未验证声明，PCK 目录记录的 MD5 相同不证明来源或版本相同。输出的 `extraction-report.json` 记录成员大小、CRC 和 SHA-256；失败的部分目录不是完成的解包，须人工检查后处理，不能覆盖重跑。

程序先用既有 7zz 只读列目录，拒绝路径穿越、大小写重复、链接、加密与备用流，再逐成员调用 `sandbox-exec` 包裹的 UnRAR `p`，通过管道写入新建的无链接、排他文件并校验内容；磁盘需至少保留总解压大小加 1 GiB。沙箱禁止网络和文件写入，限制执行到 UnRAR 与两个探针程序；限制读取 `/Users`、`/Volumes`、`/private`、`/Library`，其中放行指定输入、解码器和 dyld 缓存。它并非全系统只读白名单，7zz 列表本身不在此沙箱内。源文件提取前后检查大小、mtime、设备/节点与 SHA-256，但无法防御同权限对手在检查间替换并恢复文件。需要保持输入和私人目录可信，并在自己的 macOS 上验证沙箱生效。


### Private Simplified Chinese font-cache candidate

`strip_font_cache.py` accepts the audited v0.110.1 Windows PCK, the exact installed a9 main PCK and an official Godot 4.5.1 host. It writes a fresh, separate three-entry PCK, JSON report and private glyph-preview directory. The three fixed source paths and hashes are verified against both input packs, including unchanged import remaps. It keeps the original vector bytes and font configuration while removing prerendered size caches; it reloads the output and checks representative glyph metrics, fallback shaping and one glyph's cached image. The previews approximate the MSDF contour on the CPU and are not device-rendering proof. Python Pillow is required.

```
python3 ports/sts2/src/tools/godot_pck/strip_font_cache.py \
  --source-pck /private/original.pck --base-main /private/a9-main.pck \
  --godot /private/Godot --output /private/font-delta.pck \
  --report /private/font-report.json --evidence-dir /private/font-previews
```

The candidate must be merged before game startup: a late mounted override cannot replace a previously cached FontFile. First-use glyph generation can affect frame time; offline host timing is not a device result. Preserve the original PCK and conduct same-scene memory, font readability, fallback and first-use performance checks before deployment. `tests.test_sts2_font_cache` also checks the exact resources with an isolated Linux ARM64 Godot when its private fixtures and engine are available.

### Private common-font cache candidate

`strip_common_font_cache.py` reuses the same isolated codec for six audited common fonts against the exact Windows source PCK and 8a main PCK. It independently checks that the earlier three Simplified Chinese outputs and import mappings remain intact. It accepts only the six pinned source, vector and output hashes and a pinned delta identity; mismatches fail before publishing the staged candidate. Source-code and audit evidence remain separate from the existing three-font gate.

The CLI arguments match `strip_font_cache.py`. The worker verifies present Latin, digits and punctuation glyphs and advances at 16, 24 and 48, original versus regenerated `A` image bytes at sizes 16 and 48, variation/fallback state and vector bytes. The previews are private CPU renderings of glyph data, not device or GPU screenshots. Runtime font rendering and first-use stutter remain to be checked on the actual handheld; the 43.25 MiB total cached page data is an inventory size, not a measured RAM saving.

### Private quarter-resolution visual candidate

`quarter_texture_overlay.py` accepts only the pinned Windows source, current main pack and audited texture report. It decodes source WebP or BC once, resizes each dimension to one quarter and produces ASTC8 blocks in a separate delta; the previous main pack and regular profile are untouched. It keeps only explicitly classified card atlases, card portraits, Spine pages, room layers and simple visual effects, excluding data/shader uses, mip chains and textures whose output short/long sides would be below 128/192 pixels. The sampled alpha/color gate may retain the existing texture instead. Reports bind every input, output, codec and the parent pack; merge before startup only after independent identity and closed-set verification.

`merge_quarter_texture.py` independently recomputes the candidate and accepted sets, validates the pinned source, base, report, encoder and individual texture identities, and streams only accepted replacements into the fixed verified main pack. A rejected image remains in the parent pack; sampled compression bounds do not establish device visual fidelity.

The texture logical header and atlas region coordinates remain unchanged, but reduced pixels and ASTC8 can visibly soften art or reveal atlas edge bleed. Sampling, native headless loading and static shader-use analysis do not establish actual device appearance, runtime coverage, GPU allocation or RSS savings. The source is the original imported CTEX, not the pre-import artist PNG.

`refine_quarter_texture.py` is a separate, source-bound follow-up for rejected Spine, room and visual VFX candidates plus four audited UI images. It decodes the original CTEX once and tries ASTC8 medium and thorough settings with alpha weight 4 and alpha-aware RGB weighting. Only if neither passes does it try supported ASTC4, and only where the encoded payload is at least 5% smaller than the parent's conservative nominal base-level size. UI images keep their current physical size. All attempts use the existing sampled alpha/color limits; failed entries keep the parent texture.

`merge_refined_quarter.py` recomputes the eligible set from the prior audited report and rechecks provenance, attempt order, sampled quality and the exact accepted delta before streaming a separate, pinned main pack. The recorded encoder binary hash identifies the build report; the gate checks its source and compiler identities, not the removed temporary executable. GPU rendering and visual quality still require device validation.

The helper is built locally from ARM astcenc 5.3.0 (`bf32abd05eccaf3042170b2a85cebdf0bfee5873`), using the pinned source set and the exact compiler command recorded in its report. Pass that source directory and an ARM64 C++ compiler explicitly; the generated executable and player textures stay in the private cache. The delta must be checked and merged against its exact parent before launch. The alpha grid is sampled, not full-image equivalence; target Spine behavior, visual quality and actual memory still require device validation.

### Font-budget trial

`font_budget_trial.py` is a separate, non-default experiment pinned to the v0.110.1 Windows source and the 7ec quarter-texture parent. It checks the original import mappings, three stripped SC font identities, 46 Chinese locale inputs and the original Bold variation before generating a four-entry delta. The three FontFiles retain their complete vector data, font configuration, face and variation state, system fallback, MSDF size 48 and empty size caches; only MSDF pixel range changes from 24 to 16. The Bold shared variation points to the canonical Medium font and uses synthetic embolden 0.3, keeping its resource UID, transform and baseline. Mono and its existing monospace font are preserved. No fallback is added. The original Bold FontFile remains in the parent and can still be loaded by other references.

The worker reopens the outputs, compares data hashes and all font settings, verifies 2,493 printable game-localization codepoints and an extended 23,644-codepoint corpus against the parent, checks sampled metrics and digit advances, and loads the actual shared variations to verify canonical font instance reuse. The baseline has three missing game codepoints and system fallback remains enabled; this comparison does not guarantee all shaping sequences or dynamic text. Synthetic bold has different glyphs and advances. Smaller range can clamp thick outlines: the 928 Vulkan canvas shader divides the requested outline by scale and clamps to `range / 2 - 1`. A static scan found some scene combinations susceptible to range 16 but could not establish every runtime locale/font binding. This is an intentional visual-quality tradeoff, requiring device text and outline assessment; nominal cache pages are not RSS. The private PCK must be independently checked and combined before startup; this script neither modifies the parent nor deploys.

```sh
python3 ports/sts2/src/tools/godot_pck/font_budget_trial.py \
  --source-pck /private/windows/SlayTheSpire2.pck \
  --base-main /private/main-7ec.pck --godot /private/Godot \
  --work-dir /private/fresh-font-budget-work \
  --output /private/fresh-font-budget.pck --report /private/fresh-font-budget.json
```

`merge_font_budget_trial.py` binds the reviewed four-entry font-budget delta to the audited 099 refinement main. It verifies the Windows source and current parent identities, original import mappings, the reviewed report and output payloads before streaming a new main and standard sidecar. Every other PCK entry is copied and checksum-verified. This is a private experiment; excluding other language choices from the UI does not by itself prove their FontFiles were loaded or freed, and removing their disk resources alone is not a RAM reduction.

### Mono font subset trial

`subset_mono_font.py` creates a private one-entry delta against the exact dd5c main. It extracts and verifies the full Mono and Medium vectors, then runs the pinned [FontTools 4.60.2 pure Python wheel](https://pypi.org/project/fonttools/4.60.2/) (SHA-256 `73cf92eeda67cf6ff10c8af56fc8f4f07c1647d989a979be9e388a49be26552a`) in a fixed, network-disabled container. The partition keeps all non-CJK codepoints, variation-sequence bases, characters absent in Medium, and characters whose normalized advance differs in any Unicode cmap. Only matching CJK codepoints are delegated to a FontVariation of the canonical Medium font; the Mono shared transform, baseline, system fallback and all other font settings remain. The font timestamp is fixed and two independent subset outputs must be byte-identical.

The isolated ARM64 93d engine mounts the complete parent PCK and the one-entry delta, including its original UID cache; it checks every game codepoint, all originally supported Mono characters, sampled character widths at three sizes, digit spacing, representative strings, line metrics and reuse of the existing canonical Medium instance. FontTools' cmap and advance checks and the sampled strings do not establish identical outlines, all OpenType shaping sequences, unknown system fallback behavior, visual quality or device RSS. The byte-size difference is not a RAM measurement.

`merge_mono_subset_trial.py` rechecks the source, dd5c parent, reviewed one-entry delta and evidence, and produces a separate main with the standard PCK sidecar. `mono_subset_device_merge.py` is a separate fixed-path private trial: it verifies the selected build, the existing dd5c parent and sidecar, the only approved replacement and the final full-pack SHA. It neither edits the active bundle nor installs anything. Both use a process-local one-entry approval with an isolated merge invocation; the standard installer and its font gate are unchanged.

### Font atlas trial

`font_atlas_corpus.py` extracts the 46 English and 46 simplified-Chinese locale files from the fixed 9caf parent into a **private** fixture. `font_atlas_metrics_fixture.gd` uses the same ordered 500 present Chinese glyphs and selected real locale strings to compare the 48/16 baseline with candidate MSDF settings, without executing a game scene. In the reviewed ARM64 93d headless run the corpus held 2,493 Chinese and 104 English codepoints and 19 selected strings. Medium 48/16 used 15 RGBA8 512² pages versus 11 at 40/14 for the 500-glyph workload. This is 4 MiB of nominal CPU image data for that fixture, not measured game residency or GPU/RSS savings; other glyphs, font variations, cache lifetimes, and uploads change the outcome. The source body used for the recorded `medium-only-40-14` result has SHA-256 `38f2a71841003e29286ffd7ea3996f240402e3ed4efe2d3564c0996f50475885` (the fixture file after its three header comments). The independently regenerated private corpus SHA is `e48bc0b441ad049f6b1b2f8865bc4687886616de30a2e863b7f25ec697f24225`.

`font_atlas_trial.py` generates a separate one-entry Medium FontFile delta using the fixed source PCK, 9caf parent, host 4.5.1, ARM64 93d engine and pinned metrics report. It preserves the complete vector bytes, font settings other than MSDF size 48→40 and pixel range 16→14, and empty imported glyph cache. Mono stays at 48/16. The full-parent UID fixture checks that normal and synthetic-bold variations and the Mono subset fallback resolve to one canonical Medium instance. `merge_font_atlas_trial.py` verifies the source, parent, evidence, import map, one-entry output and all other PCK entries, producing an independent main and standard sidecar; neither script changes the installer or existing pack.

This is explicitly a quality tradeoff: at sizes 13, 16, 20, 24, 32, 48 and 72 the Medium and synthetic-bold glyph advances and line metrics differ for part of the corpus; in the selected strings synthetic bold changed by up to 7 px in width and 1 px in height. Mono's sampled individual advances and line height stayed equal, but its fallback ascent and some string heights changed. A source-derived static comparison of 192 explicit scene-size/outline pairs found four shader clamp cases for 40/14 versus six for 48/16; dynamic sizes, font selection and device rendering are not completely covered. Complex strokes in CPU MSDF previews remain recognizable, but such previews do not prove handheld readability. Changes must be separately reviewed and assessed against a controlled device run before use.

### Font fallback and canonical instances

`font_fallback_trial.py` generates a source-bound six-font fallback delta;
`merge_font_fallback_trial.py` verifies its exact parent, report and resource
closure before writing a new main. These are private comparison tools. Call
`--help` for required paths and use new output locations. The Python module also
provides localization-codepoint collection used by the font-budget and Mono
subset builders.

Fallbacks must reference the canonical `res://fonts/zhs/*.otf` source paths,
including their original import mappings. Direct `.godot/imported/*.fontdata`
aliases can create a second instance. Use `font_fallback_alias_fixture.gd` and
both `eager` / `preload` modes in `font_fallback_trial.gd` to check object identity
in fresh processes with the complete parent UID cache. A common-font fallback
can eagerly load SC even in an English menu; keep system fallback and test
coverage, metrics, shaping and actual text appearance separately.

The optional `SLL_BUNDLED_THEME_FONT=1` path is off by default. It reuses the
canonical Medium font only for the expected built-in theme, preserving the
existing Open Sans fallback and custom theme/override precedence. Run
`test_bundled_theme_font.gd` in `off`, `preload`, `after`, `custom_default` and
`custom_fallback` modes against an isolated player-provided font fixture.
`test_sc_fallback_coverage.gd` separately checks coverage without saving fonts.
The baseline SC fonts miss U+011F, U+0131 and U+0142 in the audited locale corpus;
coverage success alone does not prove that system font loading or RSS is reduced.

### Combat cover font selection

The combat cover reuses an existing Label `font` or RichTextLabel `normal_font`,
with bounded traversal and glyph checks. It accepts FontFile/FontVariation and
their safe fallback graphs, avoiding SystemFont probing. If no existing font
covers the title, it shows only the progress bar. Apply the font override, add an
empty Label to the tree to refresh theme caches, then set the title text; setting
text before insertion can trigger the previous default font's system fallback.

`build_warmup_cover_trial.py` verifies a pinned compatibility PCK, manifest and
source, then replaces only the cover script in a new private package:

```sh
python3 ports/sts2/src/tools/godot_pck/build_warmup_cover_trial.py \
  --base /PRIVATE/port_compat.pck --manifest /PRIVATE/manifest.json \
  --source ports/sts2/src/rendering/combat_warmup.gd \
  --output-dir /PRIVATE/new-cover-trial
```

`test_warmup_cover.gd` compares Label, RichTextLabel, absent/synthetic system-font
cases and the warmup lifecycle with the system-font diagnostic engine. Check
font identity, no-font fallback, title layout, cover release and input restoration.
These headless fixtures do not establish device rendering, Spine behavior,
first-attack performance or game RSS improvements.
