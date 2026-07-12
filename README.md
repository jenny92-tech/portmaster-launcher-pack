# portmaster-launcher-pack

PortMaster-style GDScript launchers for handheld arm64 game ports.
A launcher is a tiny Godot pck that pops up before the game starts so the
player can pick language / resolution / button layout / quality preset
without a keyboard. After they confirm, the launcher writes the choices
to env vars and the wrapper `sh` patches the game's config and starts it.

## Ports

| Port | Game | Engine | Godot launcher | Devices |
|---|---|---|---|---|
| [`hk`](ports/hk) | Hollow Knight | Unity 2020 Mono | Godot 4.5 | TrimUI, MiniLoong |
| [`heishenhua`](ports/heishenhua) | Wukong pixel edition | Unity 2021.3 IL2CPP | Godot 3.5 (frt) | TrimUI |
| [`vampiresurvivors114`](ports/vampiresurvivors114) | Vampire Survivors 1.14.111 | Unity 6 IL2CPP + PAD | Optional Godot 3/frt | TrimUI, MiniLoong |
| [`sts2`](ports/sts2) | Slay the Spire 2 | C# Godot 4.5 | Godot 4.5 (mono, bundled) | TrimUI, MiniLoong |
| [`batomon`](ports/batomon) | Batomon Showdown Demo | Godot 4.3 | Godot 4.x (mono, bundled) | TrimUI, MiniLoong |

Each launcher port keeps editable inputs in `src/` and generated deploy files in
`dist/`. Files in `dist/` are the only files that should be copied to a
device: `*.sh` goes to `Roms/PORTS/`, everything else goes to
`Data/ports/<port>/`.

`ports/<port>/manifest.json` is internal build metadata for this repository.
It is not a PortMaster install manifest and is not copied to `dist/`. The build
step generates PortMaster-style `dist/port.json` from it. Port images use the
standard filename `screenshot.png` in both the port root and `dist/`.

All `_kit` ports build their `bootstrap.pck` from `src/manifest.bootstrap.json` via the
shared [`_kit/pck_builder.py`](_kit/pck_builder.py) (Godot 3 / Godot 4 format
auto-detected from `godot_version`). `sts2` keeps its own
`src/scripts/make-bootstrap-pck.py` and `src/scripts/make-overlay-pck.py`
because the overlay pck and Harmony patcher need extra logic the unified builder
doesn't cover.

## Dist a port

```bash
_kit/dist_port.sh heishenhua
# → ports/heishenhua/dist/
_kit/dist_port.sh sts2
# → ports/sts2/dist/
```

## Shared kit

See [`_kit/README.md`](_kit/README.md) for the helpers each port can pull in:

- `pck_builder.py` — Godot 3 + Godot 4 pck format builder (manifest-driven)
- `portmaster_common.sh` — engine-agnostic device helpers (audio_setup with
  per-CFW branching, memory/sync/dmesg). Any port.
- `launcher_unity_common.sh` — Unity-loader layer (godot UI discovery/launch,
  button remap, run_unity_game). hk/heishenhua only, not godot ports.
- `assemble.sh` — stitches a port's `launcher.sh` template + the `_kit` libs
  into one self-contained device script inside `dist/`. See `_kit/README.md`
  for the full build → deploy recipe.
- `dist_port.sh` — builds `src/` and copies runtime/metadata into
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
  Godot 4 KMSDRM SDL2 backend (powers `sts2` + provides launcher binary)
