# Download CLI

Thin desktop entry point depending directly on portkit-core. Keep transport policy
in the core; do not add a second proxy implementation or bump package versions.

| File | Responsibility |
| --- | --- |
| `Cargo.toml` | Workspace package and direct core dependency |
| `README.md` | Invocation, limits and CI artifacts |
| `src/` | CLI and focused tests |
