# 04 — Install and Update the PortMaster Core Safely

**What to build:** Provide a separately maintained enhanced installer that can install or update the PortMaster core from a locally downloaded stable package on supported aarch64 devices. It follows the official package structure while adding the device support needed by this project and preserving all user-owned or runtime-managed content.

**Blocked by:** None — can start immediately.

**Status:** done

- [x] A clean synthetic MiniLoong device can receive a usable PortMaster core from the supplied stable package.
- [x] A clean synthetic TrimUI device can receive the same core through its correct detected installation profile.
- [x] Updating an existing core replaces only installer-owned core content and preserves games, configuration, themes, logs, caches, and user data.
- [x] The installer never modifies, backs up, restores, or validates the shared runtime library directory.
- [x] Python library content is handled correctly when supplied as an extracted directory, an archive, or both.
- [x] The enhanced installer remains separate from the upstream official installer and has fixture-based tests for every supported installation profile.
