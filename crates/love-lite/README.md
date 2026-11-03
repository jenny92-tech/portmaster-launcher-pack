# APP Manager LOVE-lite runtime

App Manager's production Rust/Lua UI host implements the LÖVE subset used by
the shared UIKit. Ordinary game launchers keep PortMaster's full LÖVE runtime.
The host embeds Lua 5.1 through `mlua`, uses SDL2 for display/input and statically
linked FreeType for lazy CJK glyph rendering at physical-pixel sizes.
Source layout is in [AGENTS.md](AGENTS.md); imported provenance and revision are
recorded in [UPSTREAM.md](UPSTREAM.md), with upstream notices preserved.

## Runtime contract

- Load a directory containing `main.lua` and optional `conf.lua`; preserve numeric
  `love.event.quit(code)`, `love.filesystem.getSource()` and in-memory `newFileData()`.
- Package as `jenny92-appmanager/runtime/love.aarch64`, targeting Debian 11 glibc
  and device SDL2. Launch directly; a missing/invalid runtime is a broken APP package.
- `auto` rendering uses accelerated SDL2 for supported rectangles, lines, polygons,
  axis-aligned circles/ellipses and cached text. Unsupported work, including stencil
  or rotated circles, uses the bounded CPU renderer. Terminal/Sixel and
  Balatro-specific behavior are excluded.
- Use SDL's real display/output dimensions when available, with platform Config
  as startup fallback. Keep text baselines and textures on the physical pixel grid.
- Clean static pages redraw only on input or Lua dirty marks. Visible toast edges
  and indeterminate spinners request 60 FPS; task progress wakes at poll rate.
- Contract tests run both the real shared UIKit and modular App Manager frontend.

## Controller calibration

SDL reads the first available controller and probes again after disconnect;
gptokeyb is not started. Load the bundled generic DB, then the database from the
Config-resolved PortMaster root, then APP-local per-GUID calibration. Shared
databases are read-only; no control script is executed. Existing SDL firmware,
built-in and explicitly exported mappings are also accepted. Missing PortMaster
does not prevent standalone use. Automatic calibration opens only when SDL cannot provide the
directions and action buttons used by the APP. A mapped reconnect dismisses the
disconnect panel. Manual recalibration is available from Settings, Home or F2;
holding arbitrary buttons does not open it.

All 12 inputs are required: four directions, A/B/X/Y, Start, Select, L1/R1. Each
step requires release. Buttons, hats and centered axis directions can supply the
d-pad; this does not calibrate analog sticks. SDL must expose raw input.
Save only to `APP/state/controller-mappings/<GUID>.txt`, preserving system and
PortMaster mappings. Calibration without a usable mapping cannot cancel; with an
existing usable mapping, A + B cancels recalibration and retains it; the previous
Start + A combination also remains available.
Outside calibration, Start/Select
do not trigger UI actions. A confirms and B returns; X/Y are reserved for
calibration and do not confirm or return in the app. Idle input is polled at most every 33 ms without
redrawing clean pages; the calibration overlay redraws while active.

## Build and test

Reproducible device build:

```sh
_kit/build_appmanager_love_lite.sh
```

Native development requires SDL2 development files discoverable by `pkg-config`:

```sh
cargo test -p love-lite --features sdl-backend
cargo build --release -p love-lite --features sdl-backend
SDL_VIDEODRIVER=dummy LOVE_LITE_SOFTWARE=1 \
  cargo run -p love-lite --features sdl-backend -- ports/appmanager/love 960 720
```

`LOVE_LITE_RENDERER=auto|gpu|cpu` selects rendering (`auto` is packaged default;
`gpu` requires acceleration). `LOVE_LITE_NATIVE_RESOLUTION=0` retains Config
dimensions for diagnostics. Software-mode smoke tests do not certify physical GPU/input.
