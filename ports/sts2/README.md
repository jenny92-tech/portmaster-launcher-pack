# STS2 Linux Launcher

*[English](README.md)*

A launcher and runtime compatibility layer for running *Slay the Spire 2* on
ARM Linux handhelds (TrimUI Smart Pro, MiniLoong Pocket One, similar
PortMaster-class devices). Built for 1 GB Mali GPUs where the stock PC build
OOMs immediately.

> The launcher does not ship game content. Players must own a legal Steam
> copy and provide the game files themselves; see
> [`src/linux/gamedata-README.md`](src/linux/gamedata-README.md) for the player-side
> recipe.

## What's in this repo

- `src/STS2LinuxLauncher/` — Harmony patcher (`sts2_compat.dll`) injected
  into the game's .NET runtime at boot. Each `Patches/*.cs` is a single
  hook with a short header comment describing what it fixes.
- `love/` — LÖVE settings UI, gptokeyb mapping, and two-stage launcher template.
- `_kit/love/kit.lua` — shared layout, focus, persistence, and env handoff,
  copied into `dist/love_ui/` during packaging.
- `src/linux/data-template/sts2.runtimeconfig.json` — generic .NET 9 self-contained
  config shipped in the launcher pack.
- `src/scripts/` — shader-overlay builder, dist assembler, and device deploy helper.
- `src/external/` — pinned CI build artifacts of the three forks listed below
  (kept in LFS).
- `dist/` — generated deployable files. `*.sh` goes to `Roms/PORTS/`;
  everything else goes to `Data/ports/sts2/`.

## External forks

| Fork | Branch | Purpose |
|---|---|---|
| [`jenny92-tech/godot`][gh-godot] | `4.5-arm64-sdl2` | Godot 4.5 mono with an SDL-only display server (SDL2 video driver owns display/EGL; no libdrm/libgbm) for PortMaster devices |
| [`jenny92-tech/fmod-gdextension`][gh-fmod] | `master` | FMOD Studio bindings for the audio layer |
| [`jenny92-tech/spine-runtimes`][gh-spine] | `4.2` | Spine 4.2 GDExtension for character animation |

[gh-godot]: https://github.com/jenny92-tech/godot
[gh-fmod]: https://github.com/jenny92-tech/fmod-gdextension
[gh-spine]: https://github.com/jenny92-tech/spine-runtimes

Each fork's CI workflow uploads ARM64 build artifacts; the current pinned
artifacts live under `src/external/<name>/`, with each `README.md` recording the
upstream workflow run and refresh command.

## Build

Requires .NET 9 SDK and Python 3.10+.

```sh
# Patcher dll → dist/data_sts2_linuxbsd_arm64/sts2_compat.dll
(cd src/STS2LinuxLauncher && dotnet build -c Release)

# Shader-overlay pck → dist/port_compat.pck
python3 src/scripts/make-overlay-pck.py
```

The patcher build references the game's `sts2.dll` and `0Harmony.dll`; place
them in `src/refs/` (gitignored) before building. See
`src/linux/gamedata-README.md` for how to obtain them.

The normal one-command path is:

```sh
_kit/dist_port.sh sts2
```

### Bundled SDL2 (Longan-class TrimUI)

Longan-class firmware ships a system SDL2 with no real video driver, and the
godot-sdl2 fork renders only through SDL-delegated GL. The port therefore
bundles a KMSDRM-enabled SDL2 at `src/runtime/sdl2-kmsdrm/libSDL2-2.0.so.0`
(committed via LFS, staged into `dist/gamedata/libs/`); the launcher probes it
at runtime and loads it for stage-2 only. Rebuild only to change the SDL
version or driver set:

```sh
ports/sts2/src/scripts/build_bundled_sdl.sh
```

The script pins debian:bullseye (device glibc is older than 2.34), enables
KMSDRM+ALSA only, and fails the build if the KMSDRM driver or the glibc
ceiling check does not pass. Note the SDL driver-name string is uppercase
"KMSDRM" — probes must grep case-insensitively.

## Distribute

`src/scripts/assemble-launcher-pack.sh` produces a redistributable launcher
pack (`dist-sts2-<date>.zip`) by:

1. Verifying source artifacts are present.
2. Building the shader-overlay PCK and compatibility DLL.
3. Downloading the Microsoft .NET 9 runtime (cached to `.cache/`).
4. Composing the on-device dist, including `love_ui/`, under `dist/`.
5. Zipping the result.

`src/scripts/MANIFEST.md` documents every file in the pack, categorized by
licence and origin. The pack contains no MegaCrit content — players provide
that separately via the `gamedata/` directory.

## Deploy (dev iteration)

`src/scripts/deploy-to-device.sh` builds `dist/` and pushes it to a device
over SSH. Use environment variables to override
the target:

```sh
DEVICE=root@<ip> PORT_PATH=/path/to/sts2 src/scripts/deploy-to-device.sh
```

## Acknowledgements

- [ModinMobileSTS/Sts2MobileLauncher][modin] — three pieces here draw on
  its work: writing the game's default settings before the process starts
  (rather than switching at runtime), the lazy asset-loading approach, and
  the shader compatibility set.
- [Harmony](https://github.com/pardeike/Harmony) by Andreas Pardeike — the
  runtime patching framework.
- [Noto Sans SC](https://fonts.google.com/noto/specimen/Noto+Sans+SC) — the CJK
  font provisioned from PortMaster's shared resources at runtime.
- [PortMaster](https://portmaster.games/) — the handheld port distribution
  framework this launcher targets.

[modin]: https://github.com/ModinMobileSTS/Sts2MobileLauncher

## License

[CC BY-NC-SA 4.0][cc-by-nc-sa] — see [`LICENSE`](LICENSE). Original code,
assets, and documentation in this repository may be shared and adapted for
non-commercial purposes with attribution and the same license. Derivatives
must remain non-commercial and credit both this project and
[ModinMobileSTS/Sts2MobileLauncher][modin].

This license grants no rights to *Slay the Spire 2* itself.
Redistribution of MegaCrit game files (including `sts2.dll`,
`SlayTheSpire2.pck`, and the third-party .NET dependencies the game
ships) is not authorised by this license and is explicitly prohibited
by the notice in `LICENSE`. Players must own a legal copy of the game.

[cc-by-nc-sa]: https://creativecommons.org/licenses/by-nc-sa/4.0/
