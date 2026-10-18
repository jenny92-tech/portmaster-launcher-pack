# Batomon Showdown Demo launcher

PortMaster launcher for the Godot 4.3 Batomon Showdown demo.

This port is intentionally a thin Godot 4 runner:

- Bundles the same `godot.mono` SDL2 fork used by the StS2 port.
- Ships the Steamworks C API stub as `libsteam_api64.so` and as
  `addons/godotsteam/linuxarm64/libsteam_api.so`.
- Leaves the game PCK and GodotSteam arm64 GDExtension as user/prep-time
  inputs, not repo assets.

## Target layout

After building `dist/`, deploy the script to `Roms/PORTS/` and everything
else to `Data/ports/batomon/`:

```
batomon/
├── Batomon Showdown.sh
├── godot.mono
├── libsteam_api64.so
├── addons/godotsteam/linuxarm64/
│   ├── libsteam_api.so
│   └── libgodotsteam.linux.template_release.arm64.so
└── gamedata/
    └── batomon_showdown.pck
```

## Game data

The original Windows demo PCK is encrypted and only declares GodotSteam
libraries for desktop platforms. This runner expects a separately prepared,
unencrypted Godot 4.3 PCK from the player's own copy. The earlier
`prepare-batomon-pck.py` helper is absent from this repository, so the launcher
does not currently provide an automatic preparation command.

The prepared pack's `addons/godotsteam/godotsteam.gdextension` must declare:

`linux.release.arm64 = "res://addons/godotsteam/linuxarm64/libgodotsteam.linux.template_release.arm64.so"`

Put the prepared PCK at `gamedata/batomon_showdown.pck`.

## Build

```bash
_kit/dist_port.sh batomon
```

Optional build inputs:

- `BATOMON_GODOTSTEAM_ARM64=/path/to/libgodotsteam.linux.template_release.arm64.so`
  copies the GodotSteam arm64 GDExtension into `dist/addons/godotsteam/linuxarm64/`.
- `STEAM_STUB=/path/to/libsteam_api64.so` overrides the default Bogodroid
  Steam API stub location.

Without `BATOMON_GODOTSTEAM_ARM64`, the dist still builds, but the game will
not get past GodotSteam loading until that library is added.
