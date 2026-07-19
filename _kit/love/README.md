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
adaptive-density layout, outlined text, rounded selects/switches/buttons, focus ring, EN/ZH
toggle, credits, QQ group, state save, env write-out.

## Component catalogue (declarative: a port declares what it uses, never renders)

**Written once in kit, never touched by a port**: header bar (`draw_bar`), rounded panel
(`panel`), layout engine (`layout` + adaptive density), focus navigation (`move_v` /
`move_h`), font and outlining (`fnt` / `outlined`).

**Shared row/page factories**:

| Factory | Purpose | Example |
|---|---|---|
| `kit.picker(label, values, labels, key)` | item with a cycling selection (`< value >`, stored in `state[key]`) | `kit.picker("resolution", RESOLUTIONS, RES_LABELS, "resolution")` |
| `kit.select(label, values, labels, key, opts)` | public Select name for `picker`; accepts stable IDs and common row options | `kit.select("quality", VALUES, LABELS, "quality", {id="quality"})` |
| `kit.button(label, action, opts)` | clickable item; action = `"start"` (exit 42) / `"quit"` (exit 0) / `"page:N"` / a function | `kit.button("start_game", "start")` |
| `kit.checkbox(label, detail, checked, callback)` | selectable list item; the options-table form supports `id`, `detail`, `checked`, `on_change` and common row options | `kit.checkbox("mods", {id="mods", checked=true, on_change=changed})` |
| `kit.switch(label, key, opts)` | state-bound two-value switch; Left turns it off, Right turns it on, Confirm toggles it | `kit.switch("rumble", "rumble", {off_value="off", on_value="on"})` |
| `kit.info(label, value)` | read-only focusable detail item | environment page |
| `kit.list_item(value, opts)` | compact one-line read-only item for dense, scrollable lists | installed Runtime names |
| `kit.section(label)` | non-focusable visual heading for grouped details | environment categories |
| `kit.add_page(title, rows)` | a page = a list of the above; page 1 is the home page | `kit.add_page("title", { picker, picker, button })` |

Form controls share one visual language: a dark inset surface, lavender outline,
bright active state and vector-drawn indicators. Select values are rendered once
without an outline shadow and centred from the font's measured height; its chevrons
and Checkbox's checkmark do not depend on font glyphs.

Body typography is rendered once on pixel-snapped coordinates so Wayland compositors
do not filter text placed between physical pixels. Only page, dialog and sidebar titles
keep one light 1 px shadow pass; body labels no longer use multi-pass outlines. A shared
`BODY_TEXT_SCALE` gives all non-title text a small readability boost while keeping the
component geometry and title hierarchy unchanged; measured TextViews account for the
larger glyphs when wrapping.

Pages optionally carry a `sidebar` button column. `kit.set_page` replaces a dynamic
page; pass `preserve_focus=true` when a selection-only rebuild must keep the current
row/sidebar control and scroll position. Give dynamic rows a stable `id` (checkbox
metadata may use `id`, `path` or `paths`) so insertions and sorting preserve the same
logical item; a removed item falls back to its nearest focusable neighbour.
Use `kit.push_page(index)` for user-driven drill-down navigation and
`kit.back_page()` for an explicit Back button. The header and semantic Cancel action
use the same history stack, restoring the previous page and focused Item ID;
`kit.goto_page(index)` remains the non-stacking API for task/state transitions.
`kit.set_busy` blocks input behind a progress overlay during background Shell work.

Input inside the Kit is semantic. `love.keypressed` translates raw keys through the
default ActionMap (`up/down/left/right/confirm/cancel`) and then calls
`kit.input(action)`. A port may add raw-key mappings with `port.input_map`; a future
native joystick adapter can call `kit.input` directly. Widgets never need to know
whether the physical source was A, B, Return or gptokeyb.

Use Checkbox for selecting zero or more list items, as APP Manager does for ports,
leftovers and trash. Use Switch for one boolean setting. `launcher.toggle(...)`
automatically renders a Switch while preserving its existing `off` / `on` state and
environment values; launcher definitions do not need to change. Switch communicates
state through knob position and colour and does not repeat redundant On/Off text.

`kit.dialog(opts)` opens a shared modal confirmation without leaving the current
page. It accepts localized `title`, `message`, `items`, `confirm` and `cancel`
values, plus `danger`, `on_confirm` and `on_cancel`. Focus is trapped inside the
modal and defaults to Cancel. Opening it pushes the current page, focus zone, stable
Item ID and scroll position onto a focus stack; closing restores that target, or its
nearest surviving neighbour after a dynamic rebuild. Ordinary launchers accept A/B as the focused action
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
and `disabled=true` (or a function) renders and skips unavailable actions. Sidebar and
content focus both use their rendered geometry, including vertical movement around
half-width pairs and spatially nearest transitions between columns. A page may also
provide `sidebar_details`, keyed by the same stable `id`/`key` used by its rows. The
Kit resolves the currently focused row's key and renders the matching wrapped context
card above bottom sidebar actions; descriptions stay correct across sorting and grid
reflow because they never depend on row indices. `sidebar_footer={lines={...}}` renders
small non-focusable identity/contact text directly above bottom actions without adding
items to the controller focus chain.
An app page with `sidebar={}` is rendered as a centred single pane; no empty action
column or divider is reserved.

Read-only content uses `kit.textview(label, value, opts)`. A TextView measures wrapped
label/value text and grows its card instead of overflowing a fixed-height row. Values
default to two lines with an ellipsis; A expands/collapses up to eight lines, capped to
the viewport. Override `max_lines`, `expanded_lines` or `expandable` when needed;
`label_px` and `value_px` provide page-specific readability tuning. `list_item` and
`section` similarly accept `font_px`. Set `surface=false` for a non-interactive status
or explanatory block that should render as plain text without a card background. Set the
page option `row_layout={mode="grid",columns=2}` for a fixed, equal-width two-column
grid (two columns are the default when `columns` is omitted), or
`row_layout={mode="flow",min_width=260}` to derive the number of equal-width columns
from the available content width. Sections always span the full row; cards sharing a
visual row use the tallest measured height so the grid remains aligned. D-pad focus
follows the resulting two-dimensional geometry and scrolling is pixel-based.
Measured Grid/Flow geometry is cached separately from focus and scrolling. Language
changes, dynamic `set_page` replacement and TextView expansion invalidate it
automatically. Code that edits a row's label/value in place should call
`kit.invalidate_layout()`; ordinary focus movement reuses the existing measurement.

Ordinary launchers use `launcher.resolution`, `launcher.select` and
`launcher.toggle`. Each field declares its default, options, localized label, env
binding and legacy source once; the schema derives state, validation, pages, old-Godot
import and `launch_config.env`. Persisted values are validated against their declared
options. State and launch environments use temporary-file + rename writes; environment
values are shell-quoted, and a failed write keeps the UI open on a Retry/Stay dialog.

**Tunable defaults** (constants at the top of kit.lua, one change applies to every port):
`ROW_MAX_W` (hard row-width cap), `ROW_MAX` / `ROW_MIN` (row height), `BAR_H` (header
height), `TITLE_PX` / `ROW_PX` / ... (type sizes), `BODY_TEXT_SCALE` (uniform non-title
type boost), `MINCS` / `MAXCS` (content-scale
bounds), and the colours in `panel()`. Ordinary launcher rows retain these global
uniform defaults; app-style TextViews opt into measured heights through a page's
`row_layout`.

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

`_love_provide_font()` therefore goes **standard first, repair to standard if broken,
fall back only if repair is impossible**. It returns the validated real path through
`LOVE_FONT_PATH`; it does not copy a healthy shared font into every launcher:

| Step | State | Action |
|---|---|---|
| ① **standard first** | healthy device, or one repaired earlier | validate the `.ttf` in `$PM_RESOURCE_DIR` / `$controlfolder/pylibs/resources`, export that exact path |
| ② **repair to standard** | standard location empty but a source exists (double-nested tar.xz / pylibs.zip) | extract Noto **into `$PM_RESOURCE_DIR`** per funcs.txt's do_init destination, then export the repaired SC path. **Fixes the broken install as a side effect** — PM's own GUI benefits, and later runs hit ① directly |
| ③ gamedir fallback | standard location cannot be repaired | reuse an old valid `love_ui/font.ttf`, or extract only SC there as a last resort |

**"Even the fallback should repair"**: ② makes the normal fallback a repair (extracting
to the standard location rather than gamedir); the double-nested `pylibs/pylibs/`
structure is left alone because it may be how LoongOS packages things. On the LÖVE side,
Kit opens `LOVE_FONT_PATH` once with standard Lua I/O, creates one `FileData`, and shares that
object across every requested size via `love.graphics.newFont(font_data, px)`. This uses
the genuinely resolved PortMaster file without LÖVE's source/save-relative path limit.
Only after `FileData` creation succeeds does Kit remove a stale per-launcher `font.ttf`;
a failed direct read therefore leaves the upgrade fallback intact.

Every step **verifies real success**: the selected shared or fallback font must pass
`_love_valid_font` (readable, exists and >1MB, rejecting 0-byte/truncated files), and
repair/extraction must actually return 0. Total failure is **not fatal**: `fnt()` first
accepts a legacy local fallback and finally uses LÖVE's built-in font (English renders,
no black screen and no crash).

Measured: TrimUI hits ① (healthy); MiniLoong in its broken state hits ② on the first run,
extracting the full Noto set to `/PortMaster/resources` (repaired), then hits ① on the
second. Both resolve the same 10,560,380-byte system font without retaining one duplicate
per launcher.

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
