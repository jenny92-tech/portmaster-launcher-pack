# 11 — Complete the Healthy-Environment Update Experience

**What to build:** Let users with a healthy PortMaster environment inspect its status, check this project's stable release, and deliberately update or reinstall through the same verified transactional flow used for repair. Update availability is informative and non-blocking until the user chooses an action.

**Blocked by:** 03 — Gate Startup on PortMaster Health; 06 — Repair a Missing Environment Through the Proxy Downloader; 10 — Follow Official Stable Releases Automatically.

**Status:** done

- [x] The home screen exposes Environment Management from the upper-left standard action and can show a small gray update-available marker.
- [x] Environment Management shows current version, latest stable version, device/profile, relevant installation paths, and a concise health status.
- [x] Check Update refreshes this project's stable metadata and reports failures without blocking normal App Manager use.
- [x] The primary update control always occupies the same place and clearly shows Up to date, Update now, or Reinstall as appropriate.
- [x] A newer or nonstandard local version is never silently downgraded; any reinstall is an explicit user choice with a clear confirmation dialog.
- [x] Update and reinstall reuse the proxy downloader, checksum checks, device risk gates, transactional installer, exit instruction, and next-launch validation.
- [x] Runtime Repair and the existing Environment Details view remain reachable from the same page and preserve their established behavior.
