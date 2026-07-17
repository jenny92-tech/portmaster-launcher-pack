# 10 — Follow Official Stable Releases Automatically

**What to build:** Run a weekly and manually triggerable workflow that checks the official stable version, does nothing when this project already has the exact complete release, and otherwise rebases the minimal fork changes onto that exact stable tag. A release is published automatically only after all candidate gates pass.

**Blocked by:** 09 — Validate the Minimal Fork as a Release Candidate.

**Status:** done

- [x] The workflow derives the official stable version from the official stable version metadata rather than a moving branch, nightly build, prerelease, or ambiguous latest tag.
- [x] If this project already has a complete public release for that exact version, the workflow exits successfully without rebuilding or mutating it.
- [x] A new stable version is rebased onto the exact matching official tag; rebase conflicts stop the workflow before build or publication.
- [x] Patch allowlist, device mocks, installer fixtures, package extraction tests, version checks, and official-installer drift checks all gate publication.
- [x] Passing validation publishes an immutable same-version release containing all assets App Manager requires.
- [x] Failed or incomplete runs never leave a public release that App Manager could mistake for a complete stable update.
- [x] The same workflow supports a manual dry run that builds and validates without publishing.
