# APP Manager LOVE-lite runtime

This crate runs Port App Manager's existing Lua/UIKit without the complete
LÖVE 11.5 runtime. It intentionally implements only the API used by APP
Manager; other launchers continue to use their existing engines.

The experiment embeds vendored Lua 5.1 through `mlua`, adapts the software
renderer from `balatro-port-tui`, and presents its RGBA framebuffer through
SDL2. The terminal/Sixel runner and all Balatro-specific patches are excluded.

## Current result

- Loads a directory containing `main.lua` and optional `conf.lua`.
- Supports the `love.*` API currently used by `_kit/love/kit.lua`.
- Implements `love.filesystem.getSource()` and in-memory `newFileData()`.
- Preserves the numeric exit code passed to `love.event.quit(code)`.
- Accepts keyboard and SDL game-controller input; Start/Select are unbound.
- Runs the real shared launcher UIKit in an automated contract test.
- Loads and draws the real modular App Manager Lua frontend in a contract test.
- Produces an approximately 2 MB aarch64 Linux release binary against Debian
  11's glibc and
  the target device's SDL2 shared library.
- Is packaged as `jenny92-appmanager/runtime/love.aarch64`; the package no
  longer carries liblove, LuaJIT, ModPlug, Ogg, or Theora.

## Build and test

The reproducible package build uses the repository helper:

```sh
_kit/build_appmanager_love_lite.sh
```

For a native developer build, SDL2 development files must be discoverable by
`pkg-config`.

```sh
cargo test -p love-lite
cargo build --release -p love-lite --features sdl-backend
```

Run the included demo:

```sh
cargo run -p love-lite --features sdl-backend -- crates/love-lite/demo 960 720
```

For a headless smoke test, use SDL's dummy video driver and the software
renderer:

```sh
SDL_VIDEODRIVER=dummy LOVE_LITE_SOFTWARE=1 \
  cargo run -p love-lite --features sdl-backend -- crates/love-lite/demo 320 240
```

Controller A confirms and B cancels by default. Set
`LOVE_LITE_CONFIRM_BUTTON=b` for a device whose physical labels are reversed.
When `SDL_GAMECONTROLLERCONFIG_FILE` names a controller database, the runner
loads it before opening controllers.

Upstream provenance and the exact imported revision are recorded in
`UPSTREAM.md`.
