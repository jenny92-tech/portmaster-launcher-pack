#!/usr/bin/env bash
# INPUT:  PortKit Cargo 构建、PortMaster 探测/封面公共库、端口模板与临时设备布局
# OUTPUT: PortMaster 定位、封面同步及模板内联断言结果
# POS:    PortMaster 引导与共享封面适配的主机侧集成测试
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cargo build --quiet --manifest-path "$ROOT/Cargo.toml" -p portkit-launcher
export PORTKIT_LAUNCHER_BIN_OVERRIDE="$ROOT/target/debug/portkit-launcher"

mkdir -p "$tmp/scripts/PortMaster"
source "$ROOT/_kit/portmaster_bootstrap.sh"
source "$ROOT/_kit/launcher_artwork.sh"
(
  XDG_DATA_HOME="$tmp/data"
  [() {
    if builtin [ "${1:-}" = -d ]; then
      builtin [ "$2" = "$XDG_DATA_HOME/PortMaster/" ]; return
    fi
    builtin [ "$@"
  }
  portmaster_discover "$tmp/scripts"
  [ "$controlfolder" = "$XDG_DATA_HOME/PortMaster" ]
)

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

for port in heishenhua hk silksong sunkendragon sts2 terraria vampiresurvivors114 recorder; do
  template="$ROOT/ports/$port/love/launcher.sh.template"
  [ -f "$template" ] || template="$ROOT/ports/$port/src/launcher.sh"
  script="$tmp/$port.sh"
  "$ROOT/_kit/assemble.sh" "$template" "$script" >/dev/null
  bash -n "$script"
  grep -Fq 'portmaster_discover()' "$script"
  grep -Fq 'portmaster_init "' "$script"
  if [ "$port" != recorder ]; then
    grep -Fq 'portmaster_sync_launcher_artwork()' "$script"
    grep -Fq 'portmaster_sync_launcher_artwork "' "$script"
  fi
  ! grep -qE '#@KIT|source "\$KIT/' "$script"
done

# Batomon now consumes the same discovery/platform and artwork adapters.
"$ROOT/_kit/assemble.sh" "$ROOT/ports/batomon/src/launcher.sh" "$tmp/batomon.sh" >/dev/null
grep -Fq 'portmaster_sync_launcher_artwork()' "$tmp/batomon.sh"
grep -Fq 'portmaster_sync_launcher_artwork "' "$tmp/batomon.sh"
grep -Fq 'portmaster_init "' "$tmp/batomon.sh"

echo "portmaster bootstrap tests: PASS"
