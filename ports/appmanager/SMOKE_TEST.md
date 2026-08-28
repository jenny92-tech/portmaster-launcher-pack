# Port App Manager device smoke test

Record the package commit, PortMaster release, firmware version, display
resolution and any controller/display difference with the result.

## MiniLoong Pocket One

- [ ] With PortMaster moved aside, `APP Manager.sh` starts from its adjacent `jenny92-appmanager/` directory and opens Environment Repair.
- [ ] A and B activate the focused choice; X and Y return; every destructive dialog initially focuses the safe action.
- [ ] Environment Repair downloads through the selected connection, shows phase/percentage/speed, and can cancel before installation.
- [ ] Update/repair reads the Jenny92 stable version and archive; Runtime metadata remains official.
- [ ] A completed repair requests an explicit exit. Reopening blocks on automatic validation before Home appears.
- [ ] Environment Management shows current/latest versions, device, health and paths; Runtime Repair and Environment Details open normally.
- [ ] Port list scanning, selection, uninstall-to-Trash, restore, leftovers and exit confirmation still work.
- [ ] Enable Remote Management while APP Manager remains open, pair from another LAN device and upload a 1–2 GiB ZIP or 7z. Close APP Manager and confirm the endpoint stops; lock-screen behavior is firmware-defined and unsupported.
- [ ] From the web UI install one Port ZIP, one APP ZIP and one password-protected 7z. A wrong password must remain retryable without another upload; cancel must remove the pending upload. Uninstall each, restore both kinds from Trash, and confirm a successful upload does not leave the transport archive in Trash.
- [ ] Put password-protected ZIP and 7z packages in a storage-card root. Install both with the controller keyboard and confirm `__MACOSX`, `.DS_Store`, and `._*` metadata neither affects recognition nor appears in installed content.
- [ ] Upload an unsupported-method ZIP/7z and a damaged archive. Confirm the web page shows the format, stable diagnostic code and specific method when known; “Copy feedback” must work over LAN HTTP and must not include a password, pairing token or device-absolute path. On-device scan results must open a diagnostic dialog instead of acting like selectable packages.

## TrimUI / chuimi

- [ ] With PortMaster moved aside, `APP Manager.sh` starts from `Roms/PORTS` using only adjacent `jenny92-appmanager/` resources and opens Environment Repair.
- [ ] A and B activate the focused choice; X and Y return. Record any physical-label difference caused by firmware mapping.
- [ ] Environment Repair reads the official stable version and targets `Apps/PortMaster/PortMaster` plus its sibling frontend files.
- [ ] Repair preserves `libs`, configuration and themes, then requests an explicit exit.
- [ ] Reopening blocks on automatic validation and reaches Home only after success; a forced validation failure restores the previous core.
- [ ] Environment Management, Runtime Repair, Environment Details and normal port operations work at the native display resolution.
- [ ] Record any clipped text, font blur, focus offset, controller mismatch or display-driver difference.
- [ ] Enable Remote Management while APP Manager remains open, complete a 1–2 GiB upload, then close APP Manager and verify the web endpoint stops. Lock-screen behavior is firmware-defined and is not a supported transfer mode.
- [ ] Pair from desktop and mobile browser widths; install, uninstall, restore and empty Trash, checking that no control overflows horizontally.
- [ ] Repeat the unsupported-method and damaged-archive diagnostic check; verify copied feedback is sanitized and the package remains uninstalled.
