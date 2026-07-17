# Port App Manager third-party runtime assets

The portable aarch64 package redistributes the following unmodified runtime
assets. Corresponding license notices are stored in this directory.

- LÖVE 11.5 and its small runtime library set: PortMaster-GUI's maintained
  `love_11.5` runtime package.
- classic gptokeyb and SDL controller database: PortMaster-GUI's aarch64
  distribution.
- Noto Sans SC Regular: the Noto CJK archive distributed by PortMaster-GUI.
- CA certificate bundle: the certifi bundle distributed by PortMaster-GUI.
- curl and its shared libraries: Alpine Linux aarch64 packages.
- BusyBox and the musl loader: Alpine Linux aarch64 packages.

The curl and BusyBox launchers deliberately resolve their adjacent musl loader
and libraries instead of relying on the handheld's glibc version. The LÖVE and
gptokeyb executables retain PortMaster's established Linux 3.7-compatible
aarch64 builds.
