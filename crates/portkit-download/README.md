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

Mirrors and public SOCKS fallbacks are inherited from the core. The bundled
registry prioritizes GitHub origin and three acceleration routes from the
[NapCat network snapshot](https://github.com/NapNeko/NapCat-Mac-Installer/blob/d2d15e6288a23287dabfc35378fa9b4735e84b2d/NapCatInstaller/Network.swift#L30-L35),
including API requests. It also retains the earlier jsDelivr Raw route and other
supplemental mirrors; duplicate full routes are tried once. jsDelivr is a Raw
source route, not a Release/API route. Each
download probes its actual target and retries remaining routes after transfer or
validation failure. The mirror snapshot is updated by rebuilding the application;
it is not a remotely refreshed list or a developer-machine availability ranking.
For Release, Raw, Archive and Gist requests, exhausting those routes tries the
embedded [public SOCKS candidates](../portkit-core/src/socks5-tested.txt) before
fetching a live list. They use proxy-side DNS (`socks5h`) and are probed against
the actual target on the user's network. The snapshot does not guarantee current
availability. If all fail, GitHub/CDN text exports supply live candidates,
cached for one hour per process.
`PORTKIT_GITHUB_SOCKS_FALLBACK_URL` replaces both the embedded pool and default
sources with one list URL per line; an empty value disables SOCKS fallback.

Use public URLs,
not private/authenticated links. File completion does not establish authenticity:
verify publisher checksums before executing downloaded files.

Build: `cargo build --release --locked -p portkit-download`.
Actions workflow is manually dispatched; Windows x64 and universal macOS (Intel
and Apple Silicon) artifacts expire after two days. No Release is published.
