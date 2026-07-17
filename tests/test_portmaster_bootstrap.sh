#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts/PortMaster"
source "$ROOT/_kit/portmaster_bootstrap.sh"
portmaster_discover "$tmp/scripts"
[ "$controlfolder" = "$tmp/scripts/PortMaster" ]

for port in heishenhua hk sts2 terraria vampiresurvivors114 appmanager; do
  template="$ROOT/ports/$port/love/launcher.sh.template"
  [ -f "$template" ] || template="$ROOT/ports/$port/src/launcher.sh"
  script="$tmp/$port.sh"
  "$ROOT/_kit/assemble.sh" "$template" "$script" >/dev/null
  bash -n "$script"
  grep -Fq 'portmaster_discover()' "$script"
  grep -Fq 'portmaster_discover "' "$script"
  ! grep -qE '#@KIT|source "\$KIT/' "$script"
done

echo "portmaster bootstrap tests: PASS"
