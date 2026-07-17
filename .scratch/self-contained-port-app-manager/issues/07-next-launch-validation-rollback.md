# 07 — Validate or Roll Back on the Next Launch

**What to build:** When App Manager reopens after a core replacement, block access to the home screen while validating the newly installed PortMaster basics. A valid environment is committed and its rollback data is removed; an invalid update is restored automatically and the user is told to exit.

**Blocked by:** 06 — Repair a Missing Environment Through the Proxy Downloader.

**Status:** done

- [x] Pending validation is detected before normal startup navigation becomes available.
- [x] The blocking validation view explains that the environment is being checked and prevents other operations until a result exists.
- [x] Validation covers the minimum core structure, version readability, device/profile detection, and essential command entry points without inspecting shared runtime libraries.
- [x] A successful validation removes the pending marker and rollback set, then allows the user to continue to the home screen.
- [x] A failed update restores the previous core, reports that the original environment was restored, and offers only an explicit exit action.
- [x] A failed first installation with no previous core removes incomplete installer-owned content, reports that no usable environment remains, and returns to the repair path on the next launch.
- [x] Automated scenarios cover success, failed update with rollback, interrupted validation, and failed first installation.
