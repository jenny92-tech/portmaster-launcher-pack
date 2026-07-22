# Port App Manager third-party assets

The portable aarch64 package redistributes the following unmodified runtime
assets. Corresponding license notices are stored in this directory.

- JSON codec: unmodified `rxi/json.lua` 0.1.2, pinned to commit
  `dbf4b2dd2eb7c23be2773c89eb059dadd6436f94`:
  <https://github.com/rxi/json.lua/blob/dbf4b2dd2eb7c23be2773c89eb059dadd6436f94/json.lua>
- LÖVE 11.5 and its small runtime library set: PortMaster-GUI's maintained
  `love_11.5` runtime package.
- ROCKNIX-family Theora decoder compatibility library: unmodified Debian 12
  arm64 `libtheora0` `1.1.1+dfsg.1-16.1+deb12u1`, downloaded from
  <https://deb.debian.org/debian/pool/main/libt/libtheora/libtheora0_1.1.1+dfsg.1-16.1+deb12u1_arm64.deb>.
  Packaged file SHA-256:
  `c4055ada0f38c34a785e8527d278218e6b77e9d48fff7c4e5b6437b0c5ecac56`.
- classic gptokeyb and SDL controller database: PortMaster-GUI's aarch64
  distribution.
- Noto Sans SC Regular: the Noto CJK archive distributed by PortMaster-GUI.
- CA certificate bundle: the certifi bundle distributed by PortMaster-GUI.
- BusyBox and the musl loader: Alpine Linux aarch64 packages.

The BusyBox launcher deliberately resolves its adjacent musl loader instead of
relying on the handheld's glibc version. HTTPS, hashes, and ZIP inspection are
implemented by the static Rust helpers. The LÖVE and gptokeyb executables retain
PortMaster's established Linux 3.7-compatible aarch64 builds.
