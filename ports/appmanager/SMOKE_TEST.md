# Port App Manager device smoke test

Record the package commit, PortMaster release, firmware version, display
resolution and any controller/display difference with the result.

- [ ] Every APP start leaves Remote off, including after a config restart or a prior enabled session. Visiting Remote does not start a listener; its switch starts/stops the service explicitly.
- [ ] Environment exposes PortMaster, Repair game Runtimes and Environment details as sibling entries. PortMaster contains no Runtime/details shortcuts, and Back restores the corresponding outer entry.
- [ ] Scan the Remote QR at 320×240, 640×480 and the native display size; verify that it fills the remaining content area, grows on larger screens and keeps its complete address/footer visible without scrolling. Its compact white margin stays visible and the decoded URL includes the current pairing code.
- [ ] In Settings, toggle A/B and X/Y independently, verify updated confirmation hints and release-before-remap behavior, then restart the APP and verify both choices are restored. Calibrated controller mapping files remain unchanged.

## Safety and recovery regressions

Use disposable fixture content for destructive and interrupted-install checks.

- [ ] Include names with spaces, two scripts sharing one folder/image, an unresolved script, and identical directory names on different cards. Preview exact managed paths; unselected, shared and uncertain data stays protected.
- [ ] Change inventory after opening an uninstall preview. Confirmation rejects the stale revision and requires a new preview.
- [ ] Cancel a Runtime download and simulate a network/validation failure. The installed Runtime remains intact, the task releases its busy state, and a retry remains available.
- [ ] Interrupt a PortMaster core swap before commit in an isolated fixture. Journal recovery restores the previous managed core/frontend; shared `libs`, configuration and themes remain intact.
- [ ] Return from a long list or dialog after refreshing/removing its focused item. Focus returns to a valid nearby target, stays visible, and skips disabled or display-only rows.

## MiniLoong Pocket One

- [ ] With PortMaster moved aside, `APP Manager.sh` starts from its adjacent `jenny92-appmanager/` directory, renders a usable UI and reports the missing core in Environment.
- [ ] A confirms and B returns; every destructive dialog initially focuses the safe action. Root navigation switches pages on focus, A enters content, B returns to navigation, and Exit remains visible at the bottom.
- [ ] Exit repeats the About artwork, author, feedback contact and complete log path; the exit question and Cancel/Confirm remain visible on small screens. B and Cancel restore focus without exiting; Confirm closes the remote service before exiting.
- [ ] Environment Repair downloads through the selected connection, shows phase/percentage/speed, and can cancel before installation.
- [ ] Update/repair reads the Jenny92 stable version and archive; Runtime metadata remains official.
- [ ] A completed repair reports success. Repeating update/repair after an interrupted fixture install verifies journal recovery before replacing managed content.
- [ ] Environment offers PortMaster maintenance, Repair game Runtimes and Environment diagnostics. Diagnostics orders gameplay risks (-25 each), PortMaster management issues (-2 each), normal/unused items (0), then all details. Show the affected games and keep the score at least 0; supported custom builds, system ownership and unused runtimes do not deduct points.
- [ ] Port list scanning and selection work. Uninstall groups exact script/image/folder paths under each game or app, Up/Down scrolls all cards, long paths remain complete, and Cancel is the default. The actions stay visible. Confirm permanently deletes only the previewed items; shared folders/images used by unselected launchers remain.
- [ ] Remote Enable/Disable uses the same top-right pale-purple action toolbar as Rescan, including below-title placement on small screens. Its full label fits and its default content focus remains on that action. Entering the page alone does not start the service; activation changes Turn on to Turn off and reveals QR/address. Verify the QR fits the available space alongside its address on small screens. Pair from another LAN device and upload a 1–2 GiB ZIP or 7z. Close APP Manager and confirm the endpoint stops; lock-screen behavior is firmware-defined and unsupported.
- [ ] From the web UI install one Port ZIP, one APP ZIP and one password-protected 7z. A wrong password remains retryable without another upload; cancel removes the pending upload. Review and uninstall each directly, checking that neither installed content nor successful transport archives remain in Trash. Test restore separately with existing Trash contents.
- [ ] Put password-protected ZIP and 7z packages in a storage-card root. Install both with the controller keyboard and confirm `__MACOSX`, `.DS_Store`, and `._*` metadata neither affects recognition nor appears in installed content.
- [ ] Upload an unsupported-method ZIP/7z and a damaged archive. Confirm the web page shows the format, stable diagnostic code and specific method when known; “Copy feedback” must work over LAN HTTP and must not include a password, pairing token or device-absolute path. On-device scan results must open a diagnostic dialog instead of acting like selectable packages.

## TrimUI / chuimi

- [ ] With PortMaster moved aside, `APP Manager.sh` starts from `Roms/PORTS` using only adjacent `jenny92-appmanager/` resources and renders a usable UI; Environment reports the core status and system ownership.
- [ ] A confirms and B returns. Verify the footer hints, immediate page selection, content → navigation → exit confirmation, and the pinned Exit action. Record any physical-label difference caused by firmware mapping.
- [ ] The second section and its page title both say “安装游戏” / “Install games”, including empty and unavailable states.
- [ ] The top left shows only “APP Manager” on wide and compact screens. All six Settings rows have equal height and spacing, with icons, text and right-hand controls vertically centered. Both swap rows and calibration share the same controller icon. Small screens scroll each item fully into view, and the compact section menu remains reachable with its labels fitting.
- [ ] PortMaster maintenance explains that the environment provider owns the core/frontend. Install, reinstall, repair and update cannot mutate those system-owned entries.
- [ ] Runtime repair and Port/APP management remain usable independently of system-owned PortMaster maintenance; existing configuration and themes remain intact.
- [ ] PortMaster maintenance, Repair game Runtimes, Environment diagnostics and normal port operations work at the native display resolution.
- [ ] Record any clipped text, font blur, focus offset, controller mismatch or display-driver difference.
- [ ] Refresh/Rescan/Scan packages and batch actions use slightly larger pale-purple buttons at the top right. At 320×240, 640×480 and native size, complete labels wrap below the title when needed without overlap; selection count changes remeasure the toolbar. Available space is plain non-focusable information with no trash icon/card background, and leftover counts are vertically centered on their action row.
- [ ] The official Fluent filled icons have smooth edges and remain distinct at the native display size: cleanup uses a trash bin, Runtime repair a wrench, diagnostics a pulse, and maintenance sliders. Check the menu, install, game/app fallback, remote, help, refresh and exit icons at small screen sizes too.
- [ ] Enable Remote Management while APP Manager remains open, complete a 1–2 GiB upload, then close APP Manager and verify the web endpoint stops. Lock-screen behavior is firmware-defined and is not a supported transfer mode.
- [ ] Pair from desktop and mobile browser widths; review a long uninstall list at 320×240 and 640×480. Scroll all paths with Cancel/Confirm always visible, verify default Cancel and stale-revision rejection, then confirm direct deletion. Existing Trash contents can still be restored or emptied; an empty Trash tab is hidden.
- [ ] Repeat the unsupported-method and damaged-archive diagnostic check; verify copied feedback is sanitized and the package remains uninstalled.
