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
| `launcher_artwork.sh` | Shared tested-device adapter for launcher artwork paths and safe same-name synchronization. |
| `portmaster_bootstrap.sh` | Shared stock/firmware/custom PortMaster discovery and initialization. |
| `launcher_platform.sh` | Inlined display/session, resolution fallback, legacy input/exec and explicit DRM ownership adapter. |
| `portmaster_common.sh` | **Engine-agnostic** device helpers: audio, memory, dmesg capture, LÖVE runtime/font/display startup. |
| `launcher_unity_common.sh` | **Unity-loader only**: configuration, button remap and game launch. |
| `assemble.sh` | Inline the `#@KIT` block of a `src/` or `love/` shell template into one self-contained device script. |
| `dist_port.sh` | Build a port and stage `love_ui/`, runtime, and metadata files into `dist/`. |
| `build_appmanager_love_lite.sh` | Build App Manager's production aarch64 LOVE-lite runtime; never used by game launchers. |
| `build_portkit_launcher.sh` | Build the small static aarch64 PortKit helper carried by game launchers that declare advanced compatibility tools. |
| `build_ffmpeg_recorder.sh` | Build the minimal static aarch64 ffmpeg (kmsgrab + mjpeg + libx264) used by the standalone Screen Recorder app. |
| `build_recorder_tool.sh` | Generate the self-contained `tools/record_screen.sh` CLI from the canonical `_kit/recorder.sh` engine. |
| `stage_portkit_launcher.sh` | Validate and copy that launcher-only binary into generated game data. |
| `dist_trimui_app.sh` | Wrap a built launcher as a TrimUI MainUI APP ZIP prefixed with `[TrimUI App]`; the archive extracts directly under `Apps/`. |
| `dist_port_zip.sh` | Build the standard PortMaster ZIP declared by `portmaster.items` and the generated `port.json`. |

## TrimUI system APP packages

```bash
_kit/dist_trimui_app.sh appmanager
_kit/dist_trimui_app.sh terraria /path/to/output
```

The archive always contains one application directory and is safe to extract
directly into `/mnt/SDCARD/Apps/`. `config.json`, `launch.sh`, and `icon.png`
are generated around the normal built launcher; the standard PortMaster package
is not changed. Ordinary game launchers include only their SH and keep using
their installed data under `Data/ports/<port>`. A self-contained application can
declare extra root-level dist items and environment variables in its manifest's
`trimui_app` object. Runtime state, trash, caches, logs, backups, and macOS
metadata are omitted. TrimUI system APPs are frontend entries and are not part
of APP Manager's Port scanning, uninstall, or leftover-cleanup model.

## GitHub transport

The Rust PortKit core treats a proxy as a typed registry entry
instead of assuming every endpoint supports every GitHub URL:

```text
id<TAB>formatter<TAB>release,raw,archive,clone,api,gist<TAB>base-url
```

Formatters include direct, full-source prefix, mirror-host replacement,
jsDelivr Raw files, and Git-smart-HTTP routes. The transport filters by
capability, probes at most five routes at once, validates content before atomic
promotion, and resumes only from the same formatted endpoint. Route hints live
only for the Rust process lifetime. APP-specific Runtime, release-manifest,
MD5/SHA-256 and ZIP validation are linked into APP Manager's single Rust process,
so its launcher carries no curl or archive/hash shell wrappers. Selected ordinary
game launchers instead package the small `bin/portkit-launcher` helper only for
operations that are unreliable across BusyBox versions. There is no complete
device-side PortKit CLI; APP Manager links shared PortKit capabilities in process.
The launchers' simple Shell
flow, PortMaster environment sourcing and game launch remain in Shell.

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
source "$KIT/launcher_platform.sh"
#@KIT-END
portmaster_init "$(cd "$(dirname "$0")" && pwd)" || exit 1
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

# ── STAGE 2: apply launcher choices + run ──
# ... configure_unity_display "$GAMEDIR/x.toml" "$WIDTH" "$HEIGHT" "$RENDER_PERCENT" || exit 1
# ... apply_button_remap "$GAMEDIR/x.toml" BUTTON_A BUTTON_B BUTTON_X BUTTON_Y
run_unity_game x.toml
# Optional second argument: colon-separated game-owned native-library dirs.
# run_unity_game x.toml "$GAMEDIR/gamedata/lib:$GAMEDIR/gamedata/lib/arm64-v8a"
```

All six Bogodroid settings launchers (hk, heishenhua, silksong, sunkendragon,
terraria, vampiresurvivors114) use `configure_unity_display`: display size and
100/75/50% internal render scale are committed together through PortKit. A failed
write stops launch. Existing per-game defaults and extra settings stay with the
port; Hollow Knight also synchronizes its own video settings to the resolved
render size. Deploy the generated script, shared `love_ui` files and matching
`bin/portkit-launcher` together, without replacing `state.txt`, `launch_config.env`,
game TOML files, saves or game assets.

The KIT block runs as-is in the repo and gets inlined by `assemble.sh` for the
device. Shared modules use `source "$KIT/<file>"`; port-private modules use
`source "$PORT_SRC/<file>"`. Both remain testable here and deployable as one
file.

## Build → dist → deploy

```bash
# 1. Assemble the shell and collect love_ui/ plus metadata.
_kit/dist_port.sh heishenhua
_kit/dist_port.sh hk

# 2. Deploy only the generated dist directory.
# MiniLoong: script -> /mnt/sdcard/roms/ports/
#              same-stem image -> /mnt/sdcard/roms/ports/<port>/
#              data -> /mnt/sdcard/roms/ports/<port>/
# TrimUI:     script -> Roms/PORTS/
#              same-stem image -> Data/ports/<port>/
#              data -> Data/ports/<port>/
```

The shared `launcher_artwork.sh` adapter copies package-owned artwork whose stem
exactly matches the selected launcher, without overwriting an existing file, to
the verified frontend path on first launch:
MiniLoong uses `Roms/PORTS/images`; TrimUI uses the TF-card `Imgs/PORTS` path
declared by its PORTS emulator config. Unknown devices are left untouched.

Launchers declaring `launcher_tools` receive the static `bin/portkit-launcher`.
It owns the fragile NotoSans extraction chain, JSON merges, shared Unity config
updates, LOVE runtime selection and update-only file sync. It does not own device
branches, environment setup or process orchestration and is not a launcher DSL.

### Platform boundary (all ordinary launchers)

The six Unity ports, STS2, Batomon and Screen Recorder use the same
`portmaster_init` entry. It accepts installed stock, firmware-provided or locally
maintained PortMaster. The compatibility code is built into the generated SH;
the device needs neither this repository nor our custom PortMaster fork.
This is **not** a PortMaster-free package: ordinary launchers still need its
standard control API and, where applicable, its LÖVE runtime, font and gptokeyb.
App Manager keeps its separate thin bootstrap and native platform configuration.

Discovery follows the [official launch-script template](https://portmaster.games/packaging.html#the-launchscript-sh):
`/opt/system/Tools/PortMaster`, `/opt/tools/PortMaster`,
`$XDG_DATA_HOME/PortMaster`, then `/roms/ports/PortMaster`.
`XDG_DATA_HOME` defaults to `$HOME/.local/share` when unset or empty.
There is no launcher-adjacent override or extra SD-card path probing. The first
existing candidate directory wins; initialization reports a missing control/API
rather than silently switching installations.

`launcher_platform_display` checks live sockets, repairs a stale runtime path and
leaves native KMS/Mali selections alone when no compositor exists. Weston owns
rotation; launchers do not rotate the game again. Supplied display dimensions are
preserved. Only the known Loong raw-fb fallback swaps portrait dimensions.
Audio setup preserves the system compositor/audio environment; non-compositor
systems retain the existing Pulse/ALSA fallback. Unknown firmware still needs
device validation; a new firmware version alone is not a compatibility guarantee.

Unity and Godot call the shared platform lifecycle. Legacy input recovery only
resumes the two known stopped input daemons; it does not read command lines,
delete lock files, restart services or raise audio-daemon OOM scores. The existing
Loong Godot process-name workaround is also isolated here. Vampire Survivors
explicitly requests exclusive DRM access; that request is ignored under a live
compositor and its paused frontend runner is restored by normal and trap cleanup.

Game settings remain game-owned: shader workarounds, fonts, render scale, frame
caps, allocator/GC tuning and Silksong's experimental AssetBundle policy are not
removed by this refactor. The known AssetBundle black screen and 1 GiB memory
budget require a separate runtime fix; launcher cleanup does not resolve them.
Game data (`unityloader`, `*.toml`, `gamedata/`) already lives in the device's game
directory and is NOT part of this launcher update — do not overwrite it or saves.

## LÖVE payload

`dist_port.sh` copies the shared kit, launcher schema, `conf.lua`, `ui.gptk` and
background, then overlays the port's Lua modules and optional asset overrides into
`dist/love_ui/`. The CJK font is provisioned from PortMaster on first launch.
See [`love/README.md`](love/README.md) for the component and device details.

Port App Manager is packaged differently: it includes a private Rust bootstrap/runtime,
font and input helper next to its UI.
