# portkit-download

Thin CLI over `portkit-core::github::GitHubTransport`; no duplicated routing,
proxy registry, retry or resume logic, and no App Manager / SDL dependency.

```sh
portkit-download "https://github.com/OWNER/REPO/releases/download/TAG/FILE.zip" -o FILE.zip
```

Windows PowerShell: use `./portkit-download.exe`. Supports GitHub release assets,
raw files, archives, API and Gist URLs accepted by the core, not arbitrary websites
or git clone. Output is required; existing destinations may be replaced using the
core's behavior. Progress goes to stderr, success to stdout; failure exits nonzero.
The shared default deadline is 30 minutes. Interrupted partial downloads retain
the core's resume behavior. No new options or configuration format are introduced.

Mirrors and public SOCKS fallbacks are inherited from the core. Use public URLs,
not private/authenticated links. File completion does not establish authenticity:
verify publisher checksums before executing downloaded files.

Build: `cargo build --release --locked -p portkit-download`.
Actions workflow is manually dispatched; Windows x64 and universal macOS (Intel
and Apple Silicon) artifacts expire after two days. No Release is published.
