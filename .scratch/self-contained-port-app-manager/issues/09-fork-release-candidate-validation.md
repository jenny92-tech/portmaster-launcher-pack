# 09 — Validate the Minimal Fork as a Release Candidate

**What to build:** Turn the maintained MiniLoong fork changes and enhanced installer into a reproducible release candidate that proves only the intended compatibility surface changed. Candidate validation must run against an exact official stable source and fail closed when the patch, installer contract, or packaged result drifts unexpectedly.

**Blocked by:** 04 — Install and Update the PortMaster Core Safely; 05 — Make Core Replacement Transactional.

**Status:** done

- [x] The candidate is based on an exact official stable tag and reports exactly the same public version value.
- [x] A strict allowlist rejects unexpected changed files while allowing only the maintained device-detection, model, test, installer, and release-automation changes.
- [x] A MiniLoong filesystem mock proves both shell and Python device detection select the intended profile.
- [x] Installer fixture tests prove the candidate package installs on the maintained MiniLoong and TrimUI profiles without touching excluded content.
- [x] The built archive is extracted into a fresh fixture and the relevant tests run again against the packaged result rather than only the source tree.
- [x] Any upstream official installer content change relative to the reviewed baseline blocks the candidate and requires deliberate human review.
- [x] The release candidate includes the PortMaster archive, enhanced installer, version metadata, and SHA256 checksums expected by App Manager.
