# _kit/love — LÖVE 2D launcher skeleton

The launcher skeleton every port uses.

## Why LÖVE

`love` ships **inside PortMaster core** — the full runtime is committed in the GUI repo
at `PortMaster/runtimes/love_<ver>/` and has been stable for 2 years — unlike `frt` /
`godot4`, which are on-demand squashfs downloads that may be missing. Combined with the
bundled font below, a love port ships **nothing of its own**: both the runtime and the
font are present on every PortMaster install. That is the core reason for picking it
(see `docs/love-kit-scope.md` in the repo root).

## Layout

```
_kit/love/kit.lua          reusable skeleton
_kit/love/launcher.lua     declarative launcher schema + presets
_kit/love/conf.lua         shared fullscreen/module configuration
_kit/love/ui.gptk          shared gamepad mapping
ports/<port>/love/
  main.lua                 fields/pages/env/legacy declarations
  launcher.sh(.template)   PortMaster launch script
```

Normal ports call `launcher.define`; dynamic apps such as APP Manager call `kit.run`
directly. The skeleton supplies: header bar,
adaptive-density layout, outlined text, rounded pickers/buttons, focus ring, EN/ZH
toggle, credits, QQ group, state save, env write-out.

## Component catalogue (declarative: a port declares what it uses, never renders)

**Written once in kit, never touched by a port**: header bar (`draw_bar`), rounded panel
(`panel`), layout engine (`layout` + adaptive density), focus navigation (`move_v` /
`move_h`), font and outlining (`fnt` / `outlined`).

**Shared row/page factories**:

| Factory | Purpose | Example |
|---|---|---|
| `kit.picker(label, values, labels, key)` | item with a cycling selection (`< value >`, stored in `state[key]`) | `kit.picker("resolution", RESOLUTIONS, RES_LABELS, "resolution")` |
| `kit.button(label, action, opts)` | clickable item; action = `"start"` (exit 42) / `"quit"` (exit 0) / `"page:N"` / a function | `kit.button("start_game", "start")` |
| `kit.checkbox(label, detail, checked, callback)` | selectable list item | APP Manager port/trash rows |
| `kit.info(label, value)` | read-only focusable detail item | environment page |
| `kit.section(label)` | non-focusable visual heading for grouped details | environment categories |
| `kit.add_page(title, rows)` | a page = a list of the above; page 1 is the home page | `kit.add_page("title", { picker, picker, button })` |

Pages optionally carry a `sidebar` button column. `kit.set_page` replaces a dynamic
page; pass `preserve_focus=true` when a selection-only rebuild must keep the current
row/sidebar control and scroll position. `kit.set_busy` blocks input behind a progress
overlay during background Shell work.

`kit.dialog(opts)` opens a shared modal confirmation without leaving the current
page. It accepts localized `title`, `message`, `items`, `confirm` and `cancel`
values, plus `danger`, `on_confirm` and `on_cancel`. Focus is trapped inside the
modal and defaults to Cancel. Ordinary launchers accept A/B as the focused action
and X/Y as return. APP Manager uses a device-specific raw a/b inversion so its
printed A confirms and printed B cancels on the target handhelds.
Only the first four item labels are shown, followed by a remaining-item count.
Apps that need guarded home-page exits can provide `port.on_home_cancel`; call
`kit.quit()` only from the dialog's confirmed callback so state is saved first.

Dynamic apps can set `port.theme={kind="app",background_dim=0.94}` for the full
application shell used by APP Manager: a tall toolbar, wide scrolling content list,
narrow titled action column, divider and scrollbar. Page options `header_action` and
`sidebar_title` fill the two toolbar areas. `kit.button` also accepts reusable options:
`half=true` pairs two actions on one row, `group="bottom"` pins navigation/quit actions,
and `disabled=true` (or a function) renders and skips unavailable actions.

Ordinary launchers use `launcher.resolution`, `launcher.select` and
`launcher.toggle`. Each field declares its default, options, localized label, env
binding and legacy source once; the schema derives state, validation, pages, old-Godot
import and `launch_config.env`.

**Tunable defaults** (constants at the top of kit.lua, one change applies to every port):
`ROW_MAX_W` (hard row-width cap), `ROW_MAX` / `ROW_MIN` (row height), `BAR_H` (header
height), `TITLE_PX` / `ROW_PX` / ... (type sizes), `MINCS` / `MAXCS` (content-scale
bounds), and the colours in `panel()`. These are **global defaults** with no per-item
override — a launcher wants every row uniform, so it never came up; add optional override
args to the factories if that changes.

**A new port = just `main.lua`**. Copy and adapt `ports/hk/love/main.lua`.

## Hard-won details (don't relearn these)

### ① Use PortMaster's bundled NotoSansSC, don't ship a font (saves ~10MB)

Every device has it, but how to get at it drifts across PM versions — so resolve it by
PortMaster's **own standard** (authority: pugwash source checks whether
`<pylibs>/resources/NotoSansTC-Regular.ttf` exists and, if not, `extractall`s the
`NotoSans.tar.xz` in the same directory into that `resources/`).

**Reuse PortMaster's own standard rather than inventing a resolution.** `control.txt`
does `source funcs.txt` (control.txt:171); funcs.txt is the official font logic and runs
automatically the moment a port sources control.txt:

- exports `export PM_RESOURCE_DIR="$controlfolder/resources"`;
- if `$controlfolder/pylibs/resources/NotoSans.tar.xz` exists → `tar -xf` in place into
  `pylibs/resources/`, deleting the tar.xz afterwards;
- if `$PM_RESOURCE_DIR/do_init` marker exists → copy `pylibs/resources/*.ttf` into
  `$PM_RESOURCE_DIR`.

So **on a healthy install the font is already in its standard location after sourcing**
and we take it with zero extraction. Canonical font paths (pugwash `PYLIB_PATH/resources`,
funcs.txt destination): `$PM_RESOURCE_DIR/NotoSansSC-Regular.ttf` and
`$controlfolder/pylibs/resources/NotoSansSC-Regular.ttf`.

The underlying source — the only thing guaranteed present on a fresh install — is
`$controlfolder/pylibs.zip`, nested three deep:
`pylibs.zip → pylibs/resources/NotoSans.tar.xz → NotoSansSC-Regular.ttf`. pugwash unpacks
the zip into a single-level `pylibs/` on first run and deletes it, **but that state is not
reliable**: MiniLoong's LoongOS runs loong_pangu instead of pugwash, and something else
unpacked the zip non-standardly into a **double-nested `pylibs/pylibs/`**. funcs.txt's
`if` hardcodes the single-level path and never matches, so the font never reached the
standard location on that device.

`provide_font()` therefore goes **standard first, repair to standard if broken, fall back
only if repair is impossible** — three steps on one line:

| Step | State | Action |
|---|---|---|
| ① **standard first** | healthy device, or one repaired earlier | read the `.ttf` from `$PM_RESOURCE_DIR` / `$controlfolder/pylibs/resources`, copy to `font.ttf` |
| ② **repair to standard** | standard location empty but a source exists (double-nested tar.xz / pylibs.zip) | extract Noto **into `$PM_RESOURCE_DIR`** per funcs.txt's do_init destination, then take SC. **Fixes the broken install as a side effect** — PM's own GUI benefits, and later runs hit ① directly |
| ③ gamedir fallback | standard location not writable ($ESUDO read-only) | last resort: extract SC to `$GAMEDIR/font.ttf`, at least it starts |

**"Even the fallback should repair"**: ② makes the fallback a repair (extracting to the
standard location rather than gamedir), so no separate gamedir-only layer is needed —
gamedir is purely the last resort when ② can't write. First line is a cache check
(`font.ttf` already >1MB → skip re-extraction). **Only the font is added to the standard
location; the double-nested `pylibs/pylibs/` structure is left alone** (it may be how
LoongOS packages things, and meddling is risky). On the love side:
`love.graphics.newFont("font.ttf", px)`.

Every step **verifies real success**: both the source font and the resulting `font.ttf`
must pass `_valid_font` (exists and >1MB, rejecting 0-byte/truncated files), and `cp`/`mv`
must actually return 0 — no false success on a read-only or full disk. Total failure is
**not fatal**: `fnt()` in `kit.lua` falls back to LÖVE's built-in font when `font.ttf` is
missing (English renders, no black screen, no crash).

Measured: TrimUI hits ① (healthy); MiniLoong in its broken state hits ② on the first run,
extracting the full Noto set to `/PortMaster/resources` (repaired), then hits ① on the
second. Both end up with the same 10,560,380-byte font.

### ② gl4es must be configured or the screen stays black

Handheld GL goes through gl4es (`LIBGL:` prefix). Left unconfigured it grabs KMS itself
and fights the frontend for DRM master → `Could not queue pageflip: -16` +
`EGL_BAD_DISPLAY` → black screen / crash. Use PortMaster's `libgl_default.txt` recipe in
the launch script:

```sh
export LIBGL_ES=2 LIBGL_GL=21 LIBGL_FB=4
[ ! -e /dev/dri/card0 ] && export LIBGL_FB=2
```

### ③ Adapt display by wayland socket (probe capability, not model) — one script covers both devices

- **`wayland-0` socket present** (MiniLoong weston): `SDL_VIDEODRIVER=wayland`, love runs
  as a compositor client, and **do not set `LIBGL_FB=4`** (that pokes KMS directly and
  fights weston). Measured: the image is **upright** — weston orients it itself, unlike
  the 90°-rotated crusty/westonwrap ports, so no rotation compensation is needed.
- **No wayland** (TrimUI, bare KMSDRM, MainUI holds DRM): don't set `SDL_VIDEODRIVER`
  (SDL picks KMSDRM), and gl4es `LIBGL_FB=4` rides its GBM/EGL context. **Must be launched
  from the frontend menu** — starting it over ssh grabs DRM.

Two traps worth remembering:

1. **Use the runtime dir the socket was found in.** Probe `$XDG_RUNTIME_DIR`, `/run`,
   `/run/user/$(id -u)`, `/var/run` in a loop and, on a hit, set XDG_RUNTIME_DIR /
   WAYLAND_DISPLAY to that one — don't let the probe path and the actual connect path
   diverge (MiniLoong's is really at `/var/run/wayland-0`).
2. **Clear inherited opposite settings.** The wayland branch does `unset LIBGL_FB` (an
   inherited FB=4 makes gl4es grab KMS on wayland → black screen); the KMS branch does
   `unset SDL_VIDEODRIVER WAYLAND_DISPLAY` (an inherited `=wayland` makes SDL connect to
   a compositor that isn't there).

### ④ Leave exactly one input path

gptokeyb translates the gamepad into keystrokes, and love can **also** read the gamepad
natively → one press travels both paths and moves two rows. Set
`t.modules.joystick = false` in `conf.lua`, leaving only gptokeyb→keyboard
(`love.keypressed`), with the mapping controlled in `.gptk` (same approach as frt).

### ⑤ Don't hardcode the love runtime version

The version is in the directory name, so glob it:

```sh
LOVE_TXT=$(ls "$controlfolder"/runtimes/love_*/love.txt | sort -V | tail -1)
```

then `source "$LOVE_TXT"` to get `$LOVE_RUN` / `$LOVE_GPTK`.

## Adaptive density (skeleton feature)

Layout does not scale linearly. The rule is **take the largest content size that still
fits**:

- small screen → content grows to fill, minimal margins (content first);
- large screen → content is capped (`MAXCS`, no stretching), surplus becomes margin
  (centred vertically);
- there is a readability floor (`MINCS`); if it genuinely doesn't fit, shrink rows first,
  then switch to scrolling (focus stays visible).

Header bar: on the home page the language key sits left; on secondary pages "‹ Back" is
top-left, the language key is right, and a faint background strip marks the visual step
down.

## Previewing small screens (without owning the device)

Temporarily add `export PAM_FORCE_W=640 PAM_FORCE_H=480` to the launch script. LÖVE
renders at that resolution, letterboxed and centred on the big screen with a corner
label — enough to eyeball a ROCKNIX 640×480 layout on a TrimUI. Delete the two lines to
return to native.

## Verification status

- ✅ TrimUI 1280×720 (bare KMS): image, Chinese (NotoSansSC), single-step focus, page
  turns, header bar, EN/ZH toggle, and the 640×480 letterbox preview layout all pass.
- ✅ MiniLoong 960×720 (wayland): image renders **upright**, font auto-extracted from
  `NotoSans.tar.xz`, wayland branch active.
- ⏳ ROCKNIX 640×480: awaiting on-device re-check (640 has only been letterbox-previewed).
- ✅ Black Myth, Hollow Knight, Terraria, Vampire Survivors 1.14, and STS2 are wired
  through the shared LÖVE stage 1 and their existing stage-2 config logic.

## Deployment (manual; launch from the menu — on TrimUI's bare KMS, starting over ssh grabs DRM)

```sh
# script → Roms/PORTS, assembled love_ui → Data/ports/<port>/love_ui/
scp ports/<port>/dist/<name>.sh root@<trimui>:/mnt/SDCARD/Roms/PORTS/<name>.sh
rsync -a ports/<port>/dist/love_ui/ \
    root@<trimui>:/mnt/SDCARD/Data/ports/<port>/love_ui/
# after adding a .sh, clear the frontend menu cache: rm Roms/PORTS/*cache*.db, then restart the frontend
```

`kit.lua` must sit in the same love directory as `main.lua` (love `require`s from the game
directory).
