# 05 — Make Core Replacement Transactional

**What to build:** Turn core installation into a recoverable transaction. Downloads and extraction happen outside the live core, cancellation is allowed before mutation, the smallest necessary rollback set is retained after replacement, and the result is marked for validation on the next App Manager launch.

**Blocked by:** 04 — Install and Update the PortMaster Core Safely.

**Status:** done

- [x] Archive validation and staging finish before any live core file is replaced.
- [x] Users can cancel safely before mutation begins; once the core swap starts, navigation and cancellation are blocked until it reaches a stable result.
- [x] Only installer-owned core content is included in the rollback set; shared runtimes and user-owned directories are excluded.
- [x] A simulated extraction or replacement failure restores the prior core without leaving a mixed installation.
- [x] A successful replacement records enough local state to distinguish first install from update and to validate or roll back on the next launch.
- [x] The completed installation tells the user to exit and reopen the app; it does not reboot the device or immediately delete the rollback set.
