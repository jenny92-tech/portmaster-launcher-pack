#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts/PortMaster"
source "$ROOT/_kit/portmaster_bootstrap.sh"
source "$ROOT/_kit/launcher_artwork.sh"
portmaster_discover "$tmp/scripts"
[ "$controlfolder" = "$tmp/scripts/PortMaster" ]

mkdir -p "$tmp/card/Roms/PORTS" "$tmp/card/Imgs/PORTS" "$tmp/card/Emus/PORTS" "$tmp/card/Data/ports/game"
: > "$tmp/card/Emus/PORTS/config.json"
printf 'image\n' > "$tmp/card/Data/ports/game/Game.png"
portmaster_sync_launcher_artwork "$tmp/card/Roms/PORTS" "$tmp/card/Roms/PORTS/Game.sh" "$tmp/card/Data/ports/game"
cmp "$tmp/card/Data/ports/game/Game.png" "$tmp/card/Imgs/PORTS/Game.png"
printf 'custom\n' > "$tmp/card/Imgs/PORTS/Game.png"
portmaster_sync_launcher_artwork "$tmp/card/Roms/PORTS" "$tmp/card/Roms/PORTS/Game.sh" "$tmp/card/Data/ports/game"
grep -Fxq custom "$tmp/card/Imgs/PORTS/Game.png"

mkdir -p "$tmp/loong/ports/game"
: > "$tmp/loong-version"
printf 'loong image\n' > "$tmp/loong/ports/game/Loong.png"
PORTMASTER_LOONG_VERSION_FILE="$tmp/loong-version" \
  portmaster_sync_launcher_artwork "$tmp/loong/ports" "$tmp/loong/ports/Loong.sh" "$tmp/loong/ports/game"
cmp "$tmp/loong/ports/game/Loong.png" "$tmp/loong/ports/images/Loong.png"

mkdir -p "$tmp/unknown/ports"
printf 'unknown image\n' > "$tmp/unknown/ports/Unknown.png"
PORTMASTER_LOONG_VERSION_FILE="$tmp/missing-version" \
  portmaster_sync_launcher_artwork "$tmp/unknown/ports" "$tmp/unknown/ports/Unknown.sh" "$tmp/unknown/ports"
[ ! -e "$tmp/unknown/ports/images" ]

mkdir -p "$tmp/no-fallback/ports/game"
printf 'generic image\n' > "$tmp/no-fallback/ports/game/screenshot.png"
PORTMASTER_LOONG_VERSION_FILE="$tmp/loong-version" \
  portmaster_sync_launcher_artwork "$tmp/no-fallback/ports" "$tmp/no-fallback/ports/Exact.sh" "$tmp/no-fallback/ports/game"
[ ! -e "$tmp/no-fallback/ports/images/Exact.png" ]

for port in heishenhua hk sts2 terraria vampiresurvivors114; do
  template="$ROOT/ports/$port/love/launcher.sh.template"
  [ -f "$template" ] || template="$ROOT/ports/$port/src/launcher.sh"
  script="$tmp/$port.sh"
  "$ROOT/_kit/assemble.sh" "$template" "$script" >/dev/null
  bash -n "$script"
  grep -Fq 'portmaster_discover()' "$script"
  grep -Fq 'portmaster_discover "' "$script"
  grep -Fq 'portmaster_sync_launcher_artwork()' "$script"
  grep -Fq 'portmaster_sync_launcher_artwork "' "$script"
  ! grep -qE '#@KIT|source "\$KIT/' "$script"
done

# The legacy Batomon runner has no PortMaster discovery Kit yet, but it still
# consumes the same public artwork adapter as every other packaged APP.
"$ROOT/_kit/assemble.sh" "$ROOT/ports/batomon/src/launcher.sh" "$tmp/batomon.sh" >/dev/null
grep -Fq 'portmaster_sync_launcher_artwork()' "$tmp/batomon.sh"
grep -Fq 'portmaster_sync_launcher_artwork "' "$tmp/batomon.sh"

echo "portmaster bootstrap tests: PASS"
