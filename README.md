# portmaster-launcher-pack

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
| [`appmanager`](ports/appmanager) | Launcher manager | LÖVE 11.5 | Shared LÖVE UI kit | TrimUI, MiniLoong |
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
`conf.lua`/`ui.gptk`, and port-specific Lua modules into `dist/love_ui/`. APP Manager
uses the same component kit; the Godot PCK builder remains only for game-runtime tooling.

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
- `pck_builder.py` — legacy/game-tool Godot PCK builder.
- `portmaster_common.sh` — engine-agnostic device helpers (audio_setup with
  per-CFW branching, memory/sync/dmesg). Any port.
- `launcher_unity_common.sh` — Unity-loader layer (button remap and
  `run_unity_game`; legacy Godot UI helpers remain for compatibility).
- `assemble.sh` — stitches a port's shell template + the `_kit` libs
  into one self-contained device script inside `dist/`. See `_kit/README.md`
  for the full build → deploy recipe.
- `dist_port.sh` — assembles `love/` or `src/` and copies runtime/metadata into
  `ports/<port>/dist/`.
- `port_json.py` — converts the repository build manifest into the PortMaster
  `port.json` shipped in `dist/`.

## License

CC BY-NC-SA 4.0 — see [LICENSE](LICENSE). Non-commercial, share-alike,
attribution required. Game assets / proprietary libraries (FMOD, Spine, etc.)
are NOT included in this repo — players provide them at install time.

## Related repos

- [Bogodroid](https://github.com/jenny92-tech/Bogodroid) — `unityloader`
  Android → arm64 Linux Unity loader (powers `hk` + `heishenhua`)
- [godot-sdl2](https://github.com/jenny92-tech/godot/tree/linuxbsd-sdl2) —
  Godot 4 KMSDRM SDL2 backend used by the STS2 game runtime
