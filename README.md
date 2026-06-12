# portmaster-launcher-pack

A collection of launchers + a shared toolkit (`_kit/`) for shipping
Linux handheld games (Unity, Godot, Java/LWJGL) on PortMaster-class
devices (TrimUI, MiniLoong, similar).

Structure follows the PortMaster New ports layout: each launcher is a
self-contained `ports/<name>/` directory; the shared kit (`_kit/`) carries
the PortMaster bootstrap, godot binary discovery, gptokeyb launching,
and pck building used across all of them.

See [`docs/architecture.md`](docs/architecture.md) for the full layout
and [`_kit/README.md`](_kit/README.md) for the shared-component API.

## Ports

| Port | Game | Engine | Status |
|---|---|---|---|
| `ports/hk/` | Hollow Knight | Unity 2020 (Mono) | TrimUI ✓ |
| `ports/heishenhua/` | 黑神话悟空像素版 | Unity 2021.3 (IL2CPP) | TrimUI ✓ (cap=512) |
| `ports/sts2/` | Slay the Spire 2 | C# Godot 4.5 mono | TrimUI ✓ MiniLoong ✓ |

## License

CC BY-NC-SA 4.0 — see [LICENSE](LICENSE). Non-commercial, attribution
required, derivative works must remain open under the same license.
Game data (`.pck` / `.jar` / Unity bundles inside `gamedata/`) is the
player's responsibility — they own a legal copy and bring it themselves.
