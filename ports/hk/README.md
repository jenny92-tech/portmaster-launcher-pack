# Hollow Knight launcher (sts2-style, PoC)

Two-stage PortMaster launcher for the Bogodroid Hollow Knight port,
adapted from sts2-linux-launcher. Stage 1 is a GDScript options UI
(`bootstrap.pck`); stage 2 sed-patches `hk.toml` from the choices and
runs `unityloader` with the original K_空洞骑士.sh memory defenses.

## Distribution model

The `dist/` directory is the launcher product — the assembled script,
bootstrap.pck, metadata, gptk, and hacksdl shim are copied from there.
Only `gamedata/` holds the game's copyrighted data, which users supply
themselves. Same split as sts2-linux-launcher's gamedata-README model:

```
ports/hollowknight/
├── assembled .sh, bootstrap.pck    ← dist/
├── unityloader, hk.toml            ← this project (Bogodroid build)
├── gamecontrollerdb.txt, conf/ …   ← this project / generated
└── gamedata/                       ← USER-SUPPLIED game data, never shipped
```

The Godot binary is NOT shipped either: stage 1 uses the PortMaster
godot runtime (`$controlfolder/libs/godot*.squashfs`, mounted for the
UI and unmounted right after). A local `godot`/`godot.mono` placed in
the port dir overrides it for debugging.

## Files

| File | Role |
|---|---|
| `src/launcher_ui.gd` | Options UI: resolution / graphics / A·B / X·Y. Writes `launch_config.env`, exits 42 to start. |
| `src/manifest.bootstrap.json` | Packs project.godot + tscn + gd + CJK font into `dist/bootstrap.pck`. No Godot editor needed. |
| `src/assets/launcher_font_zh.ttf` | LXGW WenKai Lite subset (OFL), re-subset for these UI strings. |
| `src/launcher.sh` | The two-stage port script template. |
| `dist/` | Deployable files. `*.sh` goes to `Roms/PORTS/`; everything else goes to `Data/ports/hollowknight/`. |

## Option → hk.toml mapping (all patches are idempotent seds)

| UI option | hk.toml field | Notes |
|---|---|---|
| Resolution 640x480 / 720x720 / 960x540 / 960x720 / 1280x720 | `[device] displayWidth/Height` | eglQuerySurface reports these to Unity = actual render size. Use the panel's real resolution — mismatched aspect renders off-center. Default 960x720 (= shipped hk.toml). |
| Graphics 低/中/高/极致 | `[gpu] textureMaxDim` 384/512/720/0 | Runtime texture cap; the RAM fuse. Same params as 黑神话 (heishenhua). Default 低 (384). |
| Swap A/B, Swap X/Y | `[input.remap] a/b/x/y` | Absolute values written each launch. Defaults off (HD pack 1:1 mapping is correct on MiniLoong). |

`displayRotation` is intentionally untouched — the shipped value already
works on both devices.

## Assembling the port

Build the dist first:

```bash
_kit/dist_port.sh hk
```

Then deploy:

1. Copy `dist/[中]空洞骑士.sh` to `Roms/PORTS/` (keep the PortMaster .sh naming the CFW expects).
2. Copy the rest of `dist/` to `Data/ports/hollowknight/`.
3. Godot comes from the PortMaster runtime automatically. Verify the
   squashfs exists on the device: `ls $controlfolder/libs/frt_3.*.squashfs` — if
   the CFW doesn't ship one, install a godot port once via PortMaster,
   or drop a local `godot` binary in the port dir as override.

Without godot/bootstrap.pck present, launcher.sh skips the UI and runs
the game with hk.toml as-is — safe rollback by deleting bootstrap.pck.

## Device QA checklist

- TrimUI: UI shows, D-pad navigates, A activates, choices persist
  across launches (state JSON under conf/).
- MiniLoong: panel is portrait-mounted; the UI auto-rotates 90° when it
  sees a portrait viewport. If it comes out upside-down, flip the sign
  in `_portrait_rotate` (comment in launcher_ui.gd shows both forms).
- After "Start Game": grep log.txt for `[HKL] env:` and check hk.toml
  got the chosen values; verify in-game A/B matches the picker.
- gptokeyb must NOT run during stage 1 (it EVIOCGRABs evdev and starves
  the godot UI) — launcher.sh never starts it.
