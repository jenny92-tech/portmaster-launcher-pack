# _kit — shared toolkit for portmaster-launcher-pack

Shared across all `ports/<name>/`. The repo keeps the launcher in **layers**
(clean, DRY); `assemble.sh` stitches them into **one self-contained `.sh`** for
the device, because a handheld has no copy of `_kit/` and any `source` of an
external file would make the launcher fail to start.

| File | Purpose |
|---|---|
| `portmaster_common.sh` | **Engine-agnostic** device helpers (any port): `audio_setup` (per-CFW branch), `memory_tuning`, `install_exit_trap` (dmesg post-mortem on exit). Pure function library, no top-level side effects. |
| `launcher_unity_common.sh` | **Unity-loader only** (hk, heishenhua — NOT godot ports like sts2): `find_godot_binary`, `run_godot_launcher`, `apply_button_remap`, `run_unity_game`. Depends on `portmaster_common.sh`. |
| `pck_builder.py` | Build a Godot pck (godot 3 `format_version=1` or godot 4 `format_version=3`) from a manifest.json. |
| `assemble.sh` | Inline the `#@KIT` block of a port's `launcher.sh` template into one self-contained device script (`dist/<port>.sh`). |

## How a port's launcher.sh is structured (a template)

Each `ports/<port>/launcher.sh` is a **template**: its own preamble + a KIT block
that `assemble.sh` replaces with the inlined `_kit` libraries, then port-specific
logic. Skeleton:

```bash
#!/bin/bash
PORT_NAME="heishenhua"; LOG_PREFIX="[HSH]"

# ── PortMaster preamble (controlfolder discovery + control.txt) ──
XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "/opt/system/Tools/PortMaster/" ]; then controlfolder="/opt/system/Tools/PortMaster"
... ; else controlfolder="/roms/ports/PortMaster"; fi
source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls
GAMEDIR="/$directory/ports/$PORT_NAME"; CONFDIR="$GAMEDIR/conf"; cd "$GAMEDIR"
exec > "$GAMEDIR/log.txt" 2>&1
mkdir -p "$CONFDIR" "$GAMEDIR/cache"

# ── shared helpers (assemble.sh inlines these into the device build) ──
#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../_kit" && pwd)"
source "$KIT/portmaster_common.sh"
source "$KIT/launcher_unity_common.sh"
#@KIT-END

# ── STAGE 1: launcher UI ──   (frt3 for hk + heishenhua; godot4 still supported)
if find_godot_binary frt3 && [ -f "$GAMEDIR/bootstrap.pck" ]; then
  run_godot_launcher "$GAMEDIR/bootstrap.pck"
  [ "$launcher_exit" = "0" ] && { pm_finish; exit 0; }
fi

# ── STAGE 2: patch toml from launcher choices (per-port) + run ──
# ... sed displayWidth/Height; apply_button_remap "$GAMEDIR/x.toml" ...
run_unity_game x.toml
```

The KIT block runs as-is in the repo (sources from `_kit/`) AND gets inlined by
`assemble.sh` for the device — so the template is both testable here and
deployable as one file.

## Build → deploy

```bash
# 1. Stitch the launcher into one self-contained file (dist/<port>.sh)
bash _kit/assemble.sh ports/heishenhua/launcher.sh    # → dist/heishenhua.sh
bash _kit/assemble.sh ports/hk/launcher.sh            # → dist/hk.sh

# 2. (only if launcher UI / font changed) rebuild the launcher-UI pck
python3 _kit/pck_builder.py ports/heishenhua/manifest.bootstrap.json
python3 _kit/pck_builder.py ports/hk/manifest.bootstrap.json

# 3. push to the device — launcher script → PORTS dir, pck → game dir, BACK UP FIRST
#    MiniLoong (adb 10.10.1.90):
adb -s 10.10.1.90:5555 push dist/heishenhua.sh "/mnt/sdcard/roms/ports/[中]黑神话悟空-像素版.sh"
adb -s 10.10.1.90:5555 push ports/heishenhua/build/bootstrap.pck /mnt/sdcard/roms/ports/heishenhua/bootstrap.pck
#    TrimUI (ssh 10.10.1.91):
scp dist/heishenhua.sh "root@10.10.1.91:/mnt/sdcard/mmcblk1p1/Roms/PORTS/[中]黑神话悟空-像素版.sh"
scp ports/heishenhua/build/bootstrap.pck root@10.10.1.91:/mnt/sdcard/mmcblk1p1/Data/ports/heishenhua/bootstrap.pck
```

**One assembled script serves both devices** — `audio_setup` branches on
`CFW_NAME`: on **MiniLoong (`Loong`, wayland/weston)** it leaves system audio +
`XDG_RUNTIME_DIR` untouched (override would break wayland → HK black screen /
heishenhua 90° rotation); on **TrimUI-class (KMSDRM)** it runs pulseaudio + a
`/tmp/xdg-*` fallback. Game data (`unityloader`, `*.toml`, `gamedata/`) already
lives in the device's game dir and is NOT part of the launcher — don't overwrite it.

## pck manifest

`ports/<port>/manifest.bootstrap.json`:

```json
{
  "godot_version": "4.5",
  "project_godot": "project.godot",
  "bootstrap_tscn": "bootstrap.tscn",
  "files": [
    { "res_path": "res://launcher_ui.gd",       "src_path": "launcher_ui.gd" },
    { "res_path": "res://launcher_bg.png",      "src_path": "assets/launcher_bg.png" },
    { "res_path": "res://launcher_font_zh.ttf", "src_path": "assets/launcher_font_zh.ttf" }
  ],
  "output": "build/bootstrap.pck"
}
```

Paths resolve relative to the manifest's directory, so run from anywhere:
`python3 _kit/pck_builder.py ports/<port>/manifest.bootstrap.json`.
