# 06 — Repair a Missing Environment Through the Proxy Downloader

**What to build:** Let the blocking repair screen download this project's stable PortMaster assets through the existing resilient proxy strategy, verify them, run the enhanced installer, and end with a clear reopen instruction. The user sees meaningful phases, progress, speed, and cancellation state without seeing proxy names or raw URLs.

**Blocked by:** 03 — Gate Startup on PortMaster Health; 05 — Make Core Replacement Transactional.

**Status:** done

- [x] Repair obtains the stable PortMaster archive, enhanced installer, version metadata, and SHA256 checksums only from this project's release source.
- [x] GitHub proxies and custom proxies are both supported, are probed in bounded batches of at most five, and a working candidate is selected without exposing its identity in the UI.
- [x] Interrupted downloads resume when the selected transport supports it, and a retry can change to another working candidate.
- [x] The progress view shows a human-readable phase, bytes or percentage when known, current speed, and a safe cancel action before mutation.
- [x] Every downloaded release asset is checked against the published SHA256 checksums and the archive is structurally validated before installation.
- [x] A successful repair records pending validation, displays installation completion, and exits through an explicit user action rather than entering the home screen immediately.
- [x] Network, checksum, extraction, and installer failures produce actionable dialogs or transient completion/error feedback and retain diagnostic logs.
