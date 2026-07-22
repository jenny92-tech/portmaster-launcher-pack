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

# Shared runtime assets live once in _kit; individual ports only declare their schema
# and launcher shell. dist_port.sh copies the common assets into every deployable pack.
for file in kit.lua launcher.lua conf.lua ui.gptk; do
  [ -f "$ROOT/_kit/love/$file" ] || {
    echo "_kit/love: missing shared $file" >&2
    exit 1
  }
done

# Every migrated launcher declares its legacy Godot env so existing choices survive
# the first LÖVE launch.
for port in heishenhua hk sts2 terraria vampiresurvivors114; do
  main="$ROOT/ports/$port/love/main.lua"
  grep -Fq 'launcher.define' "$main"
  grep -Fq 'legacy' "$main"
  grep -Fq 'state_path' "$main"
  for file in main.lua launcher.sh.template; do
    [ -f "$ROOT/ports/$port/love/$file" ] || {
      echo "$port: missing love/$file" >&2
      exit 1
    }
  done
  [ ! -f "$ROOT/ports/$port/love/conf.lua" ] || {
    echo "$port: conf.lua must come from _kit/love" >&2
    exit 1
  }
  [ ! -f "$ROOT/ports/$port/love/ui.gptk" ] || {
    echo "$port: ui.gptk must come from _kit/love" >&2
    exit 1
  }
done

# Build one representative port and assert the common files are materialized in dist.
bash "$ROOT/_kit/dist_port.sh" hk >/dev/null
for file in kit.lua launcher.lua conf.lua ui.gptk; do
  [ -f "$ROOT/ports/hk/dist/love_ui/$file" ] || {
    echo "hk dist: missing shared $file" >&2
    exit 1
  }
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
grep -Fq 'cp "$KIT_ROOT/love/"*.lua "$DIST/love_ui/"' "$ROOT/ports/sts2/src/scripts/dist-port.sh"
UI_ONLY=1 bash "$ROOT/_kit/dist_port.sh" sts2 >/dev/null
for file in 'Slay the Spire 2.sh' love_ui/kit.lua love_ui/launcher.lua love_ui/main.lua love_ui/ui.gptk; do
  [ -f "$ROOT/ports/sts2/dist/$file" ] || {
    echo "sts2 UI-only dist: missing $file" >&2
    exit 1
  }
done
! grep -Fq 'bootstrap.pck' "$ROOT/ports/sts2/src/scripts/deploy-to-device.sh"
! grep -Fq 'bootstrap.pck' "$ROOT/ports/sts2/src/scripts/assemble-launcher-pack.sh"
