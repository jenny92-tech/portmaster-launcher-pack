# 03 — Gate Startup on PortMaster Health

**What to build:** Detect whether the local PortMaster core is structurally usable before showing the home screen. Healthy official or customized environments proceed normally; missing or broken environments are routed to a blocking repair experience with a single-column Environment Management page.

**Blocked by:** 02 — Deliver the Self-Contained aarch64 Package.

**Status:** done

- [x] A healthy environment reaches the home screen without a blocking prompt and begins a non-blocking cached update check.
- [x] A missing or structurally broken environment cannot enter the home screen and is shown a clear repair action and an explicit exit action.
- [x] Health checks validate only the minimum core capabilities App Manager needs and do not reject an otherwise usable customized installation.
- [x] A newer or nonstandard installed version is reported without being automatically downgraded or overwritten.
- [x] Environment Management shows current version, status, detected device, installation paths, update controls, Runtime Repair, and Environment Details in one consistent single-column screen.
- [x] All back and exit behavior on the new screen is represented by explicit focusable buttons.
