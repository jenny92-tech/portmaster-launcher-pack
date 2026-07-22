# Port App Manager third-party assets

The portable aarch64 package redistributes the following unmodified runtime
assets. Corresponding license notices are stored in this directory.

- JSON codec: unmodified `rxi/json.lua` 0.1.2, pinned to commit
  `dbf4b2dd2eb7c23be2773c89eb059dadd6436f94`:
  <https://github.com/rxi/json.lua/blob/dbf4b2dd2eb7c23be2773c89eb059dadd6436f94/json.lua>
- APP Manager's Rust/Lua UI runtime derives from
  `4RH1T3CT0R7/balatro-port-tui` at commit
  `be8930d3c9fd70ab210918218f7cbffd2df1a30a`, with the API surface reduced to
  the calls exercised by APP Manager:
  <https://github.com/4RH1T3CT0R7/balatro-port-tui/tree/be8930d3c9fd70ab210918218f7cbffd2df1a30a>.
- classic gptokeyb and SDL controller database: PortMaster-GUI's aarch64
  distribution.
- Noto Sans SC Regular: the Noto CJK archive distributed by PortMaster-GUI.
- CA certificate bundle: the certifi bundle distributed by PortMaster-GUI.
- BusyBox and the musl loader: Alpine Linux aarch64 packages.

The BusyBox launcher deliberately resolves its adjacent musl loader instead of
relying on the handheld's glibc version. HTTPS, hashes, and ZIP inspection are
implemented by the static Rust helpers. The APP Manager UI runtime is its own
Linux 3.7-compatible aarch64 executable and no longer ships PortMaster's LÖVE,
LuaJIT, ModPlug, Ogg or Theora libraries.
