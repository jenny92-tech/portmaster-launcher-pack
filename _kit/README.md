# _kit — shared toolkit for portmaster-launcher-pack

Shared across all `ports/<name>/`. Migrated settings launchers live in
`ports/<name>/love/`; game/runtime sources and legacy launchers live in `src/`.
`dist_port.sh` builds them into `ports/<name>/dist/`,
which is the only directory that should be copied to a device. `assemble.sh`
stitches the shell template into **one self-contained `.sh`** because a handheld
has no copy of `_kit/` and any `source` of an external file would make the
launcher fail to start.

| File | Purpose |
|---|---|
| `love/kit.lua` | Shared LÖVE UI: pages, items, buttons, split layout, focus, localization and busy state. |
| `love/launcher.lua` | Declarative state/options/env/legacy schema for ordinary game launchers. |
| `github_proxy.sh` | Capability-aware GitHub transport: Release/Raw/Archive/API/Gist downloads and Git clone, with per-proxy URL formatters, bounded probing, same-route resume, validation and fallback. |
| `portmaster_bootstrap.sh` | Shared PortMaster control-folder discovery. |
| `portmaster_common.sh` | **Engine-agnostic** device helpers: audio, memory, dmesg capture, LÖVE runtime/font/display startup. |
| `launcher_unity_common.sh` | **Unity-loader only**: configuration, button remap and game launch. |
| `assemble.sh` | Inline the `#@KIT` block of a `src/` or `love/` shell template into one self-contained device script. |
| `dist_port.sh` | Build a port and stage `love_ui/`, runtime, and metadata files into `dist/`. |

## GitHub transport

`github_proxy.sh` treats a proxy as a registry row instead of assuming every
endpoint supports every GitHub URL:

```text
id<TAB>formatter<TAB>release,raw,archive,clone,api,gist<TAB>base-url
```

Formatters currently include `direct`, `full` (prefix the complete source
URL), `mirror` (replace `github.com`), `jsdelivr` (Raw files only), and
`gitclone` (Git smart HTTP only). `github_proxy_fetch` filters by capability,
probes at most five routes at once, downloads through responsive routes, and
accepts a route only after the caller's content validator succeeds.
`github_proxy_clone` performs the equivalent flow for Git clone. Range data is
resumed only from the same route ID; changing routes discards the old partial.
New endpoints can be appended as TSV rows through
`GITHUB_PROXY_REGISTRY_EXTRA`; callers do not edit the download operations.

Git LFS, GitHub Packages, and GHCR are intentionally not modeled as file
downloads: they have separate authenticated protocols. Add them as distinct
operations if the APP ever needs them.

## How a port's launcher.sh is structured (a template)

Each `ports/<port>/love/launcher.sh.template` is a **template**: its preamble + a KIT block
that `assemble.sh` replaces with the inlined `_kit` libraries, then port-specific
logic. Skeleton:

```bash
#!/bin/bash
PORT_NAME="heishenhua"; LOG_PREFIX="[HSH]"

# ── PortMaster preamble (shared discovery + control.txt) ──
#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/portmaster_bootstrap.sh"
#@KIT-END
portmaster_discover "$(cd "$(dirname "$0")" && pwd)"
source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls
GAMEDIR="/$directory/ports/$PORT_NAME"; CONFDIR="$GAMEDIR/conf"; cd "$GAMEDIR"
exec > "$GAMEDIR/log.txt" 2>&1
mkdir -p "$CONFDIR" "$GAMEDIR/cache"

# ── shared helpers (assemble.sh inlines these into the device build) ──
#@KIT-BEGIN
KIT="$(cd "$(dirname "$0")/../../../_kit" && pwd)"
source "$KIT/portmaster_common.sh"
source "$KIT/launcher_unity_common.sh"
#@KIT-END

# ── STAGE 1: shared LÖVE launcher UI ──
run_love_launcher_ui

# ── STAGE 2: patch toml from launcher choices (per-port) + run ──
# ... sed displayWidth/Height; apply_button_remap "$GAMEDIR/x.toml" ...
run_unity_game x.toml
```

The KIT block runs as-is in the repo (sources from `_kit/`) AND gets inlined by
`assemble.sh` for the device — so the template is both testable here and
deployable as one file.

## Build → dist → deploy

```bash
# 1. Assemble the shell and collect love_ui/ plus metadata.
_kit/dist_port.sh heishenhua
_kit/dist_port.sh hk

# 2. Push to the device from dist/ only.
#    MiniLoong (adb 10.10.1.90):
adb -s 10.10.1.90:5555 push ports/heishenhua/dist/[中]黑神话悟空-像素版.sh "/mnt/sdcard/roms/ports/[中]黑神话悟空-像素版.sh"
adb -s 10.10.1.90:5555 push ports/heishenhua/dist/love_ui /mnt/sdcard/roms/ports/heishenhua/
#    TrimUI (ssh 10.10.1.91):
scp ports/heishenhua/dist/[中]黑神话悟空-像素版.sh "root@10.10.1.91:/mnt/sdcard/mmcblk1p1/Roms/PORTS/[中]黑神话悟空-像素版.sh"
rsync -a --exclude='*.sh' ports/heishenhua/dist/ root@10.10.1.91:/mnt/sdcard/mmcblk1p1/Data/ports/heishenhua/
```

**One assembled script serves both devices** — `audio_setup` branches on
`CFW_NAME`: on **MiniLoong (`Loong`, wayland/weston)** it leaves system audio +
`XDG_RUNTIME_DIR` untouched (override would break wayland → HK black screen /
heishenhua 90° rotation); on **TrimUI-class (KMSDRM)** it runs pulseaudio + a
`/tmp/xdg-*` fallback. Game data (`unityloader`, `*.toml`, `gamedata/`) already
lives in the device's game dir and is NOT part of the launcher — don't overwrite it.

## LÖVE payload

`dist_port.sh` copies the shared kit, launcher schema, `conf.lua`, `ui.gptk` and
background, then overlays the port's Lua modules and optional asset overrides into
`dist/love_ui/`. The CJK font is provisioned from PortMaster on first launch.
See [`love/README.md`](love/README.md) for the component and device details.
