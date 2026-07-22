# Upstream provenance

This experiment adapts the LOVE API and software pixel-buffer implementation
from [`4RH1T3CT0R7/balatro-port-tui`](https://github.com/4RH1T3CT0R7/balatro-port-tui).

- Upstream commit: `be8930d3c9fd70ab210918218f7cbffd2df1a30a`
- Imported: 2026-07-22
- Upstream license: Apache-2.0
- Imported directories: `love-api` and `sprite-to-text/src/pixel_buffer.rs`

The terminal runner, Sixel/Ratatui renderer, screenshots, Balatro assets and
Balatro-specific Lua patches were intentionally not imported. Local changes
replace Crossterm event collection with an external-backend seam, add the
filesystem calls required by the launcher UIKit, and provide an SDL2 runner
with an APP-specific GPU command renderer and software fallback.

Font parsing and on-demand glyph rasterization use statically linked FreeType
with auto-hinting instead of the upstream eager `fontdue` parser.

See `LICENSE-UPSTREAM-APACHE-2.0.txt` for the upstream license text.
