# Shared LÖVE UIKit

Shared controller-first UI for game settings and App Manager. Ports declare pages
and fields; layout, focus, rendering and persistence stay in the kit.
File navigation is in [AGENTS.md](AGENTS.md).
The [focus navigation design](FOCUS-NAVIGATION.md) records grouping, spatial
selection, scrolling and focus-restoration principles with their source references.

Buttons, checkboxes and switches use a pinned [LUIS component subset](luis/README.md)
through `ui_components.lua`. `ui_theme.lua` supplies the shared purple surfaces,
inset focus borders and control colors for both runtimes. Kit remains the public
page API and owns focus, scrolling, text and safe confirmation defaults. Component
activation settles its tween immediately, so idle pages still sleep on input.
Additional widgets can move behind this adapter without changing port declarations.

## Components and pages

| API | Purpose |
|---|---|
| `kit.button` | Action row, including half-width and bottom-pinned actions |
| `kit.select` / `kit.picker` | Selection with stable values |
| `kit.checkbox` / `kit.switch` | Multiple choice / boolean setting |
| `kit.info` / `kit.list_item` | Read-only facts / scrollable compact list rows |
| `kit.textview` | Wrapping, optionally expandable content |
| `kit.qrcode` | Offline L-level QR view with integer modules and a compact two-module margin |
| `kit.section` / `kit.badge` | Non-focusable grouping and status |
| `kit.dialog` / `kit.toast` | Focus-trapped dialog / temporary result |
| `kit.set_busy` | Progress overlay with optional cancellation |
| `kit.add_page` / `kit.set_page` | Create / replace page contents |
| `kit.push_page` / `kit.back_page` | History-aware drill-down navigation |

In a single-column App page, `kit.qrcode(...,{fit_available=true})` fills the
remaining content width/height after reserving space for the other rows. QR
modules remain whole physical pixels; the address and footer stay visible.

Rows accept stable `id`, `detail`, `disabled`, `half`, `group` and typography
options. Stable IDs preserve selection, scroll and sidebar details after refresh.
`row_layout={mode="grid",columns=2}` uses fixed columns; `mode="flow"` derives
columns from `min_width`. Sections span the width; each line uses its tallest row.
Matching `inline` values group content actions or filters into a separate line;
`inline_columns` sets that line's columns; its first row's `max_width` caps each
button's design width. `active` marks a selected destination
or filter; `default_focus` selects the initial content row. App buttons, pickers
and switches share the same leading `icon` slot and explicit `height` sizing,
including the same compact-screen scale. Buttons also accept
`appearance="action"` or `danger` treatment.

Functional icons use the official Microsoft Fluent filled SVG subset in
`icons/`, with its MIT license and pinned source revision. The checked-in atlas
contains antialiased integer pixel sizes for the handheld renderer; rebuild it
with `node _kit/build_ui_icons.cjs` when Sharp is available.

`port.theme={kind="app"}` enables the App navigation and content shell.
Functional roots use `root=true,navigation=true` with destination buttons in
`sidebar`. Wide screens show a left navigation column; below 600 physical pixels
the single-row header opens a section menu. Left or Cancel opens navigation;
Right or Confirm enters content. Cancel from navigation invokes `on_home_cancel`.
Inline siblings consume horizontal input
first. Destination IDs start with `nav:` and use `select_on_focus=true`: moving focus selects the page
immediately while focus stays in the navigation. Right or Confirm enters content
without selecting the destination twice. Contextual actions still require Confirm.
Navigation keeps readable text and row sizes on short displays: the selected
destination scrolls into view, with chevrons for more entries and Exit pinned below.
Active navigation and control focus are separate states. `goto_page`
clears child history when selecting a root; `push_page` preserves it for details.
App Manager uses `app_shell.lua` to keep the same functional navigation on secondary
pages and places contextual actions in a fixed header toolbar. Back restores child
history and focus. Other callers may still declare contextual action sidebars.
`row_layout.max_width` caps reading width without scaling a virtual canvas.

An empty sidebar reserves no column or divider. `sidebar_details` uses row IDs;
`sidebar_footer` is non-focusable. `surface=false` draws a plain row.
`kit.empty(value,opts)` creates a plain empty-state message without an icon or focus stop.
`kit.select(...,{dropdown=true})` opens an anchored option list with Confirm;
Up/Down moves within it, Confirm applies the selection, and Cancel restores focus
without changing the value. A blank label uses the whole control for its value.
`kit.font(px)` shares the measured body font with custom overlays. TextView
`description` appears inside its expanded content; paths prefer directory boundaries.
App list rows, tabs, navigation and primary/secondary actions have distinct themes.
Dialog titles, password keys and progress metrics use measured heights so actions
remain separate from text on small screens.

`kit.dialog({items=paths,scroll_items=true,...})` shows one complete item at a time.
Up/Down reviews every entry; long paths wrap and overflow pans without ellipses.
Left/Right chooses the action, with Cancel selected by default.
App dialogs place Cancel on the left and Confirm on the right. Informational
results use `single_action=true` for one acknowledgement; Cancel still dismisses.
An optional `identity={thumbnail=path,title=name,subtitle=author}` places app
artwork and credits above the message, with the confirmation question below it.
Long text wraps and pans while the actions remain fixed.
`kit.dialog({item_groups={{title=name,items=paths},...},...})` instead shows a
scrolling list of grouped cards. Each group owns its full wrapped paths; Up/Down
scrolls, page keys move by a viewport, and the action buttons remain outside the
scrolling region. Uninstall uses this form, with Cancel selected initially.

## Focus and input

`focus_view.lua` resolves focus through page → body → content/tools → controls.
Search within the current container before moving to a sibling or parent;
boundaries do not wrap. Editable pickers consume left/right first, dialogs trap
focus, and returning from a header or subpage restores the previous content scope.
The renderer exposes this hierarchy, not an arbitrary public View API.

Vertical movement prefers horizontal overlap; horizontal movement prefers vertical
overlap. Tools use content coordinates vertically and screen coordinates across
columns. Half-width siblings share one scroll row; focus is scrolled fully into
the viewport on the same frame, excluding indicator bars. Disabled items and
display-only text are skipped. Compact list rows remain focusable scroll targets;
expandable TextViews accept focus unless `focusable=false`.

Widgets consume `up`, `down`, `left`, `right`, `confirm`, `cancel` via `kit.input`.
Ordinary launchers disable native joystick input and use gptokeyb keyboard events;
App Manager receives SDL controller input through its LOVE-lite host. Ordinary
confirm mappings accept either face-button convention; App Manager has its own
mapping: A confirms and B returns; saved A/B and X/Y swaps correct controller
recognition while the on-screen button labels stay unchanged. Dialogs
default to the safe action. App roots return from content to navigation, then to
exit confirmation. An explicit Exit action stays at the bottom of navigation.

## Settings and persistence

`launcher.define` derives defaults, validation, localization, env output and
one-time legacy import from field declarations. Ordinary fields use
`launcher.output_resolution`, `launcher.render_scale`, `launcher.memory_mode`,
`launcher.select`, `launcher.toggle`.

Unity main pages contain render resolution, Rudroid memory mode and optional game
language. Output size, picture mode, texture limits, FPS, decorations, effects and
button swaps belong to Advanced. Game preset preserves existing TOML dimensions;
memory values are `low_memory`, `balanced` (default), `performance`. Experimental
C ports must not advertise Rudroid memory policy.

`state.txt` and `launch_config.env` live under `love.filesystem.getSource()`.
Both use temporary-file/rename writes; env values are shell-quoted. Failed
write/close/rename or a false custom-writer result keeps the UI open for retry;
the previous complete env stays intact. Shell handoff requires exit 42 and a
newly saved, nonempty env.

## Text and layout

Text uses physical pixel-snapped coordinates. Layout measurements and scroll
bounds are cached until content, language or expansion changes. Use
`kit.invalidate_layout()` after editing rows in place; `kit.set_page` does it.

TextViews retain full text. Overflow pans at 12 scaled pixels/second with two-second
end pauses; fitting text stays still. `max_lines` limits visible height only.
`preserve_lines=true` keeps explicit lines and shrinks within bounds before
scrolling, including the complete remote URL with its pairing code.
APP layout scales below the 480p density floor on smaller displays so its columns
and the complete remote URL/code fit at 320×240. Header titles fit between their
controls; sidebar footers reserve the actual height of wrapped text.

## Graphics and runtime

Only Silksong and Vampire Survivors expose the OpenGL ES / Vulkan picker.
All five Rudroid launchers default to OpenGL ES and 75% rendering; Vulkan remains
a manual choice for those two titles. Existing valid saved choices still apply.
Runtime features, title support and a bounded native probe determine availability.
Invalid saved APIs are corrected before display/save; explicit unavailable APIs
are rejected before TOML changes. Unsupported controls display Disabled and skip
focus. `requires_feature` supplies a safe `unavailable_value`; a backend without
scaling emits 100% while retaining the saved percentage for capable backends.
Filtering follows the backend/title preset. Refresh on startup or option changes,
not every frame; memory and game-level quality remain independent.

Shell owns runtime discovery, display environment and shared-font preparation;
see [shared kit](../README.md). App Manager packages its own runtime and font so
its repair UI can start before PortMaster discovery. The cross-repository model
and ownership are documented in [App Manager](../../ports/appmanager/README.md)
and the [configuration contract](../../config/README.md).

## Build and verify

```sh
_kit/dist_port.sh hk
_kit/dist_port.sh appmanager
bash tests/test_love_shared_components.sh
python3 tests/test_love_lua_modules.py
python3 tests/test_appmanager_environment_ui.py
```

Python UI tests require `lupa` and report SKIP if absent. Deploy generated
`ports/<port>/dist/` payloads, not editable templates.

APP 导航页采用中性深灰和浅紫焦点。列表按钮可声明 `thumbnail`（只读图片路径）、`library_item=true`（封面列表行）；`selection_item=true` 使用右侧勾选与左侧封面。`header_toolbar=true` 使操作固定在标题区域，`toolbar_width` 和 `toolbar_align="right"` 控制紧凑工具栏；页面 `toolbar_row=true` 将工具放在标题下，按实测文字宽度换行。`form_field=true` 让字段在宽屏左右对齐，小屏和路径上下排列。小屏将页面选择与退出放在顶栏，工具栏保留在列表上方。所有 APP 确认框取消在左、确认在右，默认取消；分组卸载确认小屏全屏显示，B 返回。

`toolbar_auto=true` 在空间足够时把操作与标题放在同一行，空间不足时在标题下方分行；每行保留左侧筛选、右侧操作的排列。App Manager 的操作按钮统一使用 `appearance="toolbar"` 的淡紫底色、52 设计像素行高和20字号。`metric` 是无卡片底色、无图标的数值展示；信息行应设置 `focusable=false`。
