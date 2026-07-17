# 08 — Protect Untested and Unsupported Devices

**What to build:** Allow the same repair and update flow to operate across devices without pretending every profile has been verified. Tested devices proceed normally, officially supported but untested devices require one acknowledgement, and devices unsupported by the official model require a second acknowledgement plus confirmation of the detected installation path.

**Blocked by:** 03 — Gate Startup on PortMaster Health; 06 — Repair a Missing Environment Through the Proxy Downloader.

**Status:** done

- [x] MiniLoong and TrimUI are identified as tested profiles and do not receive the untested warning.
- [x] An officially supported but untested profile requires an unchecked acknowledgement that the operation will modify the PortMaster environment.
- [x] An officially unsupported profile additionally requires a separate unchecked acknowledgement of missing official support and explicit confirmation of the proposed installation path.
- [x] Both acknowledgements must be individually focused and activated before the install or update action becomes available.
- [x] A device whose safe target path cannot be determined is refused rather than assigned a guessed location.
- [x] Dialogs default to a non-destructive action and remain usable when A and B both activate the focused choice.
- [x] Synthetic profile tests cover tested, untested-official, unsupported-with-known-path, and unknown-path devices.
