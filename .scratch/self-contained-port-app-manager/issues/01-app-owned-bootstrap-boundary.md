# 01 — Establish the App-Owned Bootstrap Boundary

**What to build:** Make Port App Manager resolve its launcher, resources, writable state, and child-process environment from an app-owned location while preserving the currently working launch path during the transition. A packaged fixture must prove that the new boundary is usable without changing existing user-visible behavior yet.

**Blocked by:** None — can start immediately.

**Status:** done

- [x] A packaged App Manager resolves its resources and writable state relative to its own launcher instead of assuming PortMaster initialized the process.
- [x] App-owned environment values are passed explicitly to child processes and do not depend on inherited PortMaster shell state.
- [x] Existing installations continue to launch through the transitional compatibility path.
- [x] Automated package-level tests cover paths containing spaces and a synthetic device filesystem.
- [x] The new boundary gives later tickets one documented place to substitute bundled runtime assets and PortMaster installation targets.
