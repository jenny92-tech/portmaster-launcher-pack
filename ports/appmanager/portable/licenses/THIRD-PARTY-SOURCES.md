# Port App Manager third-party assets

The portable aarch64 package redistributes the following runtime
assets. Corresponding license notices are stored in this directory.

- APP Manager's Rust/Lua UI runtime derives from
  `4RH1T3CT0R7/balatro-port-tui` at commit
  `be8930d3c9fd70ab210918218f7cbffd2df1a30a`, with the API surface reduced to
  the calls exercised by APP Manager:
  <https://github.com/4RH1T3CT0R7/balatro-port-tui/tree/be8930d3c9fd70ab210918218f7cbffd2df1a30a>.
- The UI runtime statically links FreeType through `freetype-sys` for lazy,
  auto-hinted glyph rasterization. FreeType is distributed under the FreeType
  Project License; the Rust binding is MIT licensed.
- ZIP support is provided by `zip` 2.4.2 (MIT). 7z decoding, common codec
  support and AES password handling are provided by `sevenz-rust2` 0.20.2
  (Apache-2.0). The standard Apache-2.0 text included as
  `LICENSE-love-lite-APACHE-2.0.txt` also covers `sevenz-rust2`.
- classic gptokeyb and SDL controller database: PortMaster-GUI's aarch64
  distribution. The database retains its original mappings and adds the following
  Linux hardware mappings (2026-09-24); no same-GUID overrides are applied:
  - `19003982010000008811000088010000`, `r36s_Gamepad`: UnofficialOS
    [c0216667562e50b26525b9a0e75ccbffb87c221a](https://github.com/RetroGFX/UnofficialOS/blob/c0216667562e50b26525b9a0e75ccbffb87c221a/packages/emulators/tools/gamecontrollerdb/config/gamecontrollerdb.txt),
    including its corrected `guide:b10` binding.
  - `1900f6a24b480000df14000000010000`, `H700 Gamepad`: ROCKNIX
    [19427e5d51ae4426c42f11e15fae4c3399326da8](https://github.com/ROCKNIX/distribution/blob/19427e5d51ae4426c42f11e15fae4c3399326da8/projects/ROCKNIX/packages/apps/gamecontrollerdb/config/gamecontrollerdb.txt).
  These are driver/GUID-specific mappings, not claims of compatibility with every
  R36S clone or H700 firmware. The existing GO-Super mapping remains unchanged.
  - 21 additional Linux GUIDs from AURKNIX
    [9cf9ebeeb6dba95d336f310a1a28ef339a5c6abd](https://github.com/lcdyk0517/distribution_aurknix/blob/9cf9ebeeb6dba95d336f310a1a28ef339a5c6abd/projects/ROCKNIX/packages/apps/gamecontrollerdb/config/gamecontrollerdb.txt).
    All 25 upstream entries were considered: 21 added in full, 2 already identical,
    and 2 same-GUID conflicts resolved below. No entries or optional mapping fields
    are discarded merely because the APP does not use those controls.
    APP checks cover navigation, confirm/cancel and L1/R1 paging; Guide, triggers,
    stick clicks and right-stick coverage are not required. A/B swaps and X/Y
    swaps are equivalent for this APP's ui.gptk. The existing R36S mapping is
    retained (AURKNIX merely lacks Guide); the GO-Ultra same-GUID mapping is NOT
    overwritten because it changes essential button and direction assignments.
    Zed and H700 mappings already match. These additions are not device-tested.
  - 20 complete `muOS-Keys` mappings from MustardOS/internal
    [3c4c47f8d18fa1e0aecd364ce5639782eff3a333](https://github.com/MustardOS/internal/tree/3c4c47f8d18fa1e0aecd364ce5639782eff3a333/device),
    using each device's `control/gamecontrollerdb/retro.txt`. Modern variants
    only swap A/B and X/Y, equivalent for this APP; do not install duplicate GUIDs.
  - Four additional GUIDs from the pinned ROCKNIX source above: GKD Pixel 2,
    MANGMI Pocket Max and two InputPlumber controllers. All upstream fields are
    retained, including controls not used by APP Manager. Existing same-GUID
    mappings are untouched. These additions still need device validation.
- Noto Sans SC Regular: the Noto CJK archive distributed by PortMaster-GUI.
- CA certificate bundle: the certifi bundle distributed by PortMaster-GUI.

HTTPS, hashes, ZIP/7z inspection, filesystem operations, task coordination, device
resolution, and the Lua UI host are linked into the single LOVE-lite Rust main
executable. The package no longer ships separate PortKit/APP Manager helper
processes or PortMaster's LÖVE, LuaJIT, ModPlug, Ogg or Theora libraries.
