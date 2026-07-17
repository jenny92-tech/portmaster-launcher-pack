# 02 — Deliver the Self-Contained aarch64 Package

**What to build:** Ship an aarch64 Port App Manager package that opens its complete UI when PortMaster and all PortMaster-provided environment variables are absent. The package owns every runtime asset required to start, render Chinese text, receive classic controller input, and perform HTTPS downloads.

**Blocked by:** 01 — Establish the App-Owned Bootstrap Boundary.

**Status:** done

- [x] The packaged app starts successfully after the synthetic PortMaster tree and PortMaster environment variables are removed.
- [x] The package includes LÖVE 11.5, a complete Chinese font, classic aarch64 gptokeyb, controller mappings, curl, BusyBox, CA certificates, and their required license notices.
- [x] The actual resolved bundled font is used; startup does not silently fall back to a PortMaster font.
- [x] A and B both activate the currently focused safe action, while return, cancel, and exit remain explicit focusable UI choices.
- [x] The release package contains only the assets required for the independent aarch64 application and passes the package contract tests.
