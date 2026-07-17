# 12 — Remove Legacy Bootstrap Dependencies and Certify the Release

**What to build:** Complete the expand-contract migration by removing every remaining startup dependency on PortMaster-provided LÖVE, fonts, controller helpers, and shell initialization. Produce the final independent aarch64 package and verify the full repair, update, validation, and rollback experience before distribution.

**Blocked by:** 07 — Validate or Roll Back on the Next Launch; 08 — Protect Untested and Unsupported Devices; 11 — Complete the Healthy-Environment Update Experience.

**Status:** done

- [x] No production startup path sources PortMaster initialization or resolves LÖVE, fonts, gptokeyb, controller mappings, download tools, or certificates from PortMaster.
- [x] Transitional fallback code introduced for the migration is removed, and package contract tests fail if a legacy dependency returns.
- [x] The final package starts and reaches the correct repair screen on a clean synthetic device with no PortMaster content or environment variables.
- [x] The full automated suite covers healthy startup, first installation, update, reinstall, cancellation, checksum failure, failed update rollback, failed first install, and unknown-device refusal.
- [x] A MiniLoong smoke checklist verifies independent startup, environment repair, required exit/reopen validation, Runtime Repair navigation, and normal App Manager operations.
- [x] A TrimUI smoke checklist verifies the same journey and records any device-specific controller or display differences.
- [x] The distributable contains only the launcher, adjacent app resources, required notices, and documented placement instructions; it does not bundle user data or shared runtime libraries.
