# Port App Manager device smoke test

Record the package commit, device firmware version, display resolution and any controller/display difference with the result.

## MiniLoong Pocket One

- [ ] With PortMaster moved aside, `APP Manager.sh` starts from its adjacent `PortAppManager/` directory and opens Environment Repair.
- [ ] A and B activate the focused choice; X and Y return; every destructive dialog initially focuses the safe action.
- [ ] Environment Repair downloads through the selected connection, shows phase/percentage/speed, and can cancel before installation.
- [ ] A completed repair requests an explicit exit. Reopening blocks on automatic validation before Home appears.
- [ ] Environment Management shows current/latest versions, device, health and paths; Runtime Repair and Environment Details open normally.
- [ ] Port list scanning, selection, uninstall-to-Trash, restore, leftovers and exit confirmation still work.

## TrimUI / chuimi

- [ ] With PortMaster moved aside, `APP Manager.sh` starts from `Roms/PORTS` using only adjacent `PortAppManager/` resources and opens Environment Repair.
- [ ] A and B activate the focused choice; X and Y return. Record any physical-label difference caused by firmware mapping.
- [ ] Environment Repair targets `Data/ports/PortMaster`, preserves `libs`, configuration and themes, then requests an explicit exit.
- [ ] Reopening blocks on automatic validation and reaches Home only after success; a forced validation failure restores the previous core.
- [ ] Environment Management, Runtime Repair, Environment Details and normal port operations work at the native display resolution.
- [ ] Record any clipped text, font blur, focus offset, controller mismatch or display-driver difference.
