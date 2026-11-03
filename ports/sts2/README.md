# STS2 Linux Launcher

A launcher and runtime compatibility layer for *Slay the Spire 2* on ARM64
Linux handhelds, combining the shared LÖVE settings UI, Harmony patches,
mobile shader overlays and separately prepared Godot Mono runtimes.

Players must own a legal copy and provide the game files. The launcher does
not include game content. See the [resource guide](src/linux/gamedata-README.md)
and [development guide](DEVELOPMENT.md) for supported inputs and build steps.

## Device profiles and graphics

The settings page offers Auto, SDL2 (OpenGL) and Vulkan. Auto resolves the
verified device preference. An explicitly unavailable selection is retained
but cannot start the game. Switching takes effect on the next start and uses
the same save location.

| Device profile | Vulkan | SDL2 / OpenGL ES 3 |
|---|---|---|
| MiniLoong / LoongOS | PortMaster Godot Mono, the live system Wayland session and the private Wine/Godot WSI | Unavailable: native Wayland EGL initialization has not passed |
| TrimUI / A523 | PortMaster Godot Mono, an owned private Weston session and the Rudroid native Vulkan layer | Matched SDL Godot with a private KMSDRM-enabled SDL2 runtime |

These profiles require a verified board, firmware, installation and library
identity. An IP address or SoC name does not establish support for another
device. TrimUI also requires an owned frontend display handoff;
MiniLoong requires a working native Wayland connection.

The PortMaster `godot_4.5.mono.aarch64.squashfs` used by these profiles reports
`4.5.1.rc.mono.custom_build.928ee7023`. It is not an upstream stable release.
The private WSI libraries adapt application presentation without replacing the
system Mali driver. TrimUI's native layer does not start an Android/Unity loader.

Both profiles use **Je-杀戮尖塔2[中]** as the menu entry. Existing independent
installations and their saves remain intact. Deploy only generated `dist/`
content according to the target profile.

## Settings

- **Force Composition** is an on/off switch for TrimUI Vulkan, defaulting to on.
  On requests Weston composition with `RUDROID_WAYLAND_FORCE_RENDERER=1`;
  off removes that request. It is disabled for GLES and MiniLoong's current route.
- **Performance Info** shows FPS, frame time, memory, texture estimates and the
  actual graphics backend. **Diagnostic Log** retains a bounded recent log.
  Both are off by default; the log switch does not enable private resource scans,
  UI control or `--verbose`.
- Engine-specific A/B and X/Y swaps remain disabled until a complete native
  controller mapping is verified. Saved preferences are retained.

Resource-size estimates are not measured GPU allocation or RSS. Input, text
quality, first-use stutter, combat and normal exit need verification on the
actual device; host checks alone do not establish a memory or performance target.

## Build and runtime sources

The launcher build requires .NET 9 SDK, Python 3.11+ and player-provided
`sts2.dll` / `0Harmony.dll` under the ignored `src/refs/` directory:

```sh
_kit/dist_port.sh sts2
```

This builds the repository launcher template. Rebuilding optimized game data,
assembling external runtimes and updating a verified installed profile are
separate operations described in [DEVELOPMENT.md](DEVELOPMENT.md).
The [pack manifest](src/scripts/MANIFEST.md) records component origins and licenses.

| Source | Branch | Purpose |
|---|---|---|
| [jenny92-tech/godot](https://github.com/jenny92-tech/godot) | `4.5-arm64-sdl2` | SDL Godot source and shared-runtime development |
| [jenny92-tech/fmod-gdextension](https://github.com/jenny92-tech/fmod-gdextension) | `master` | FMOD Studio bindings |
| [jenny92-tech/spine-runtimes](https://github.com/jenny92-tech/spine-runtimes) | `4.2` | Spine character animation extension |

SDL and Vulkan profiles currently use separately matched engines. A unified
custom engine must pass native/managed API and device validation before
replacing either runtime. Provenance and expected filenames are documented
under `src/external/`; supply binaries under their own licenses.

## Acknowledgements and license

- [ModinMobileSTS/Sts2MobileLauncher](https://github.com/ModinMobileSTS/Sts2MobileLauncher)
  and [sts2-android-compat](https://github.com/ModinMobileSTS/sts2-android-compat):
  startup settings, lazy-loading ideas and shader compatibility work.
- [Harmony](https://github.com/pardeike/Harmony): runtime patching.
- [Noto Sans SC](https://fonts.google.com/noto/specimen/Noto+Sans+SC) and
  [PortMaster](https://portmaster.games/): shared font and handheld runtime ecosystem.

Original code, assets and documentation use [CC BY-NC-SA 4.0](LICENSE), with
attribution to this project and ModinMobileSTS/Sts2MobileLauncher. Third-party
components retain their licenses. This license grants no rights to the game;
redistribution of MegaCrit game files is prohibited by the notice in LICENSE.
