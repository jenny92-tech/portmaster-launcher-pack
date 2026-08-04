# Hollow Knight launcher

Two-stage PortMaster launcher for the Bogodroid Hollow Knight port. Stage 1 is
the shared LÖVE 11.5 settings UI; stage 2 applies the selected resolution,
texture cap, and ABXY layout before running `unityloader`.

## Distribution model

```text
ports/hollowknight/
├── love_ui/                       ← this repository's dist
├── unityloader, unityloader.libs/ ← one Bogodroid build unit
├── unityloader.d/
│   ├── android_base.so
│   ├── unity_2021_3.so
│   ├── platform_sdl_runtime.so
│   ├── sdk_fmod.so
│   └── hollow_knight_viewport.so
├── config.toml                    ← Bogodroid port configuration
├── gamecontrollerdb.txt, conf/ …  ← runtime/generated
└── gamedata/                      ← user-supplied game data
```

`sdk_fmod.so` supplies the Android FMOD/AudioTrack bridge; without it the game
runs silently. `hollow_knight_viewport.so` owns the 4:3 camera and tk2d hooks.
The loader, private libraries and all selected plugins must come from the same
Bogodroid build because the loader rejects mixed runtime fingerprints.

The settings runtime is supplied by PortMaster at
`runtimes/love_11.5`; this port no longer ships or mounts a Godot/frt runtime,
`bootstrap.pck`, hacksdl, or a launcher font.

## Files

| File | Role |
|---|---|
| `love/main.lua` | Declares resolution, graphics, ABXY options, persistence, and env output. |
| `love/conf.lua` | Fullscreen LÖVE configuration with duplicate joystick input disabled. |
| `love/ui.gptk` | Gamepad-to-keyboard navigation mapping for stage 1 only. |
| `love/launcher.sh.template` | Two-stage PortMaster shell template. |
| `dist/` | Deployable assembled shell, `love_ui/`, metadata, and screenshots. |

Existing Godot-launcher choices are imported once from the legacy
`conf/godot/app_userdata/Hollow Knight Launcher/launch_config.env`; subsequent
state lives in `love_ui/state.txt`.

## Options

| UI option | Runtime field |
|---|---|
| Resolution | `displayWidth` / `displayHeight` and Hollow Knight graphics settings |
| Graphics | `textureMaxDim`: 384 / 512 / 720 / 0 |
| Swap A/B, Swap X/Y | `[input.remap]` absolute button values |

## Build and deploy

```bash
_kit/dist_port.sh hk
```

Copy `dist/[中]空洞骑士.sh` to `Roms/PORTS/` and the rest of `dist/` to
`Data/ports/hollowknight/`.

Device QA should cover both bare-KMS TrimUI and Wayland MiniLoong: UI rendering,
single-step D-pad focus, persistence, env logging, and in-game button mapping.
