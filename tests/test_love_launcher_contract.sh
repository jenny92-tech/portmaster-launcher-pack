#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Direct assemble.sh usage must resolve ports/<port>/love/ back to the port root.
out="$("$ROOT/_kit/assemble.sh" "$ROOT/ports/hk/love/launcher.sh.template" "$tmp/hk.sh")"
grep -Fq 'assembled hk' <<<"$out"
bash -n "$tmp/hk.sh"
! grep -qE '#@KIT|source "\$KIT/' "$tmp/hk.sh"

# Every migrated launcher declares its legacy Godot env so existing choices survive
# the first LÖVE launch, and every package carries the shared UI inputs.
for port in heishenhua hk sts2 terraria vampiresurvivors114; do
  main="$ROOT/ports/$port/love/main.lua"
  grep -Fq 'port.legacy_env' "$main"
  grep -Fq 'state_path' "$main"
  for file in main.lua conf.lua ui.gptk launcher.sh.template; do
    [ -f "$ROOT/ports/$port/love/$file" ] || {
      echo "$port: missing love/$file" >&2
      exit 1
    }
  done
done

python3 - "$ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for port in ("heishenhua", "hk", "sts2", "terraria", "vampiresurvivors114"):
    manifest = json.loads((root / "ports" / port / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["launcher"].startswith("LÖVE 11.5"), port
    assert manifest["gptk"] == "love/ui.gptk", port
    assert "godot_launcher" not in manifest, port
PY

# STS2's managed patcher consumes these through process environment variables.
grep -Fq 'export SLL_LANGUAGE SLL_QUALITY' "$ROOT/ports/sts2/love/launcher.sh.template"
grep -Fq 'PortPaths.Get("SLL_QUALITY")' "$ROOT/ports/sts2/src/STS2LinuxLauncher/QualityProfile.cs"
grep -Fq 'love_ui/main.lua' "$ROOT/ports/sts2/src/scripts/deploy-to-device.sh"
grep -Fq 'love_ui/kit.lua' "$ROOT/ports/sts2/src/scripts/assemble-launcher-pack.sh"
! grep -Fq 'bootstrap.pck' "$ROOT/ports/sts2/src/scripts/deploy-to-device.sh"
! grep -Fq 'bootstrap.pck' "$ROOT/ports/sts2/src/scripts/assemble-launcher-pack.sh"
