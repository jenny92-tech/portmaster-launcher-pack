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
| `portable_tools.sh` | Capability probe and process-local all-or-nothing switch from system applets to an application-provided BusyBox. |
| `launcher_artwork.sh` | Shared tested-device adapter for launcher artwork paths and safe same-name synchronization. |
| `portmaster_bootstrap.sh` | Shared PortMaster control-folder discovery. |
| `portmaster_common.sh` | **Engine-agnostic** device helpers: audio, memory, dmesg capture, LÖVE runtime/font/display startup. |
| `launcher_unity_common.sh` | **Unity-loader only**: configuration, button remap and game launch. |
| `assemble.sh` | Inline the `#@KIT` block of a `src/` or `love/` shell template into one self-contained device script. |
| `dist_port.sh` | Build a port and stage `love_ui/`, runtime, and metadata files into `dist/`. |
| `build_appmanager_native.sh` | Build and stage Port App Manager's static aarch64 Rust helpers. |
| `dist_trimui_app.sh` | Wrap a built launcher as a TrimUI MainUI APP ZIP prefixed with `[TrimUI App]`; the archive extracts directly under `Apps/`. |

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

The static Rust `portkit` helper treats a proxy as a typed registry entry
instead of assuming every endpoint supports every GitHub URL:

```text
id<TAB>formatter<TAB>release,raw,archive,clone,api,gist<TAB>base-url
```

Formatters include direct, full-source prefix, mirror-host replacement,
jsDelivr Raw files, and Git-smart-HTTP routes. `portkit github fetch` filters by
capability, probes at most five routes at once, validates content before atomic
promotion, and resumes only from the same formatted endpoint. Route hints live
only for the Rust process lifetime. APP-specific Runtime and stable-manifest
validation is exposed by `appmanager-cli`; MD5/SHA-256 and ZIP inspection are
provided by `portkit file`, so launchers do not carry curl or archive/hash shell
wrappers.

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

Port App Manager is packaged differently: it includes a private bootstrap runtime,
font, input and network tools next to its UI. See
[`../docs/architecture.md`](../docs/architecture.md) for the repository boundary and
publication routing.
