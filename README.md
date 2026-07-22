# PortMaster Launcher Pack

PortMaster-style launchers for handheld arm64 game ports. The normal stage-1
UI uses PortMaster's bundled LÖVE 11.5 runtime so players can pick language,
resolution, button layout, and quality without a keyboard. After confirmation,
the UI writes a small env file and the wrapper shell patches the game config.

## Ports

| Port | Game | Engine | Settings launcher | Devices |
|---|---|---|---|---|
| [`hk`](ports/hk) | Hollow Knight | Unity 2020 Mono | LÖVE 11.5 | TrimUI, MiniLoong |
| [`heishenhua`](ports/heishenhua) | Wukong pixel edition | Unity 2021.3 IL2CPP | LÖVE 11.5 | TrimUI |
| [`terraria`](ports/terraria) | Terraria | Unity 2021.3 IL2CPP | LÖVE 11.5 | PortMaster aarch64 |
| [`vampiresurvivors114`](ports/vampiresurvivors114) | Vampire Survivors 1.14.111 | Unity 6 IL2CPP + PAD | LÖVE 11.5 | TrimUI, MiniLoong |
| [`sts2`](ports/sts2) | Slay the Spire 2 | C# Godot 4.5 | LÖVE 11.5 | TrimUI, MiniLoong |
| [`appmanager`](ports/appmanager) | Port and environment manager | Bundled LÖVE 11.5 + static Rust helpers | Shared LÖVE UI kit | TrimUI, MiniLoong, muOS, ROCKNIX family, Knulli, Batocera, Miyoo |
| [`batomon`](ports/batomon) | Batomon Showdown Demo | Godot 4.3 | None (direct game runner) | TrimUI, MiniLoong |

Migrated launchers keep stage-1 inputs in `love/`; game-specific runtime and
build sources remain in `src/`. Generated deploy files live in `dist/`, the only
directory that should be copied to a
device: `*.sh` goes to `Roms/PORTS/`, everything else goes to
`Data/ports/<port>/`.

`ports/<port>/manifest.json` is internal build metadata for this repository.
It is not a PortMaster install manifest and is not copied to `dist/`. The build
step generates PortMaster-style `dist/port.json` from it. Port images use the
standard filename `screenshot.png` in both the port root and `dist/`.

LÖVE launchers package the shared `kit.lua`, declarative launcher schema, common
`conf.lua`/`ui.gptk`, and port-specific Lua modules into `dist/love_ui/`. Port App
Manager uses the same component kit, but packages its own bootstrap runtime and
static Rust helpers so it can repair a missing PortMaster environment. Godot
game-runtime tooling stays inside the relevant port.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — current cross-repository ownership,
  download routing, installation safety and PortMaster Fork release flow.
- [`_kit/README.md`](_kit/README.md) — build system and shared Shell modules.
- [`_kit/love/README.md`](_kit/love/README.md) — public UIKit and launcher contract.
- [`ports/appmanager/README.md`](ports/appmanager/README.md) — Port App Manager behavior,
  resource sources and safety boundaries.
- [`config/README.md`](config/README.md) — generated device configuration contract,
  safety rules and validation commands.

## Dist a port

```bash
_kit/dist_port.sh heishenhua
# → ports/heishenhua/dist/
_kit/dist_port.sh sts2
# → ports/sts2/dist/
```

## Shared kit

See [`_kit/README.md`](_kit/README.md) for the helpers each port can pull in:

- `love/kit.lua` — shared LÖVE layout, input, state, and env handoff layer.
- `portmaster_common.sh` — engine-agnostic device helpers (audio_setup with
  per-CFW branching, memory/sync/dmesg). Any port.
- `launcher_unity_common.sh` — Unity-loader configuration, button remap and
  `run_unity_game`.
- `assemble.sh` — stitches a port's shell template + the `_kit` libs
  into one self-contained device script inside `dist/`. See `_kit/README.md`
  for the full build → deploy recipe.
- `dist_port.sh` — assembles `love/` or `src/` and copies runtime/metadata into
  `ports/<port>/dist/`.
- `port_json.py` — converts the repository build manifest into the PortMaster
  `port.json` shipped in `dist/`.
- `build_appmanager_native.sh` — builds the static aarch64 `portkit` and
  `appmanager-cli` helpers embedded in Port App Manager.

## License

CC BY-NC-SA 4.0 — see [LICENSE](LICENSE). Non-commercial, share-alike,
attribution required. Game assets / proprietary libraries (FMOD, Spine, etc.)
are NOT included in this repo — players provide them at install time.

## Related repos

- [Bogodroid](https://github.com/jenny92-tech/Bogodroid) — `unityloader`
  Android → arm64 Linux Unity loader (powers `hk` + `heishenhua`)
- [godot-sdl2](https://github.com/jenny92-tech/godot/tree/linuxbsd-sdl2) —
  Godot 4 KMSDRM SDL2 backend used by the STS2 game runtime
