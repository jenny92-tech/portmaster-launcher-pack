#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import importlib.util
import json
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "ports/appmanager/manifest.json").read_text())
assert manifest["engine_status"] == "production"
assert manifest["engine_scope"] == "appmanager-only"
assert manifest["app_id"] == "com.jenny92.portappmanager"
assert manifest["app_id"] == manifest["trimui_app"]["package"]

crate = tomllib.loads((root / "crates/love-lite/Cargo.toml").read_text())
assert crate["package"]["version"].startswith("1.")

spec = importlib.util.spec_from_file_location(
    "cargo_revision", root / "_kit/cargo_revision.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
lock = tomllib.loads((root / "Cargo.lock").read_text())
closure = {record["name"] for record in module.lock_dependency_closure(lock, ["love-lite"])}
assert "love-lite" in closure
assert "mlua" in closure
assert "portkit-core" in closure
assert "appmanager-core" in closure
assert "appmanager-service" in closure
assert "appmanager-cli" not in closure
assert "clap" not in closure
native = {
    record["name"]
    for record in module.lock_dependency_closure(lock, ["appmanager-service", "appmanager-cli"])
}
assert "appmanager-core" in native
assert "portkit-core" in native
assert "love-lite" not in native
assert "mlua" not in native
PY

grep -Fq 'Engine::load_appmanager' "$ROOT/crates/love-lite/src/main.rs"
! grep -Fq 'AppInstanceLock' "$ROOT/crates/love-lite/src/main.rs"
grep -Fq 'runtime/love.aarch64' "$ROOT/ports/appmanager/src/launcher.sh"
! grep -Fq 'launcher-session' "$ROOT/ports/appmanager/src/launcher.sh"
! grep -Fiq 'this experiment' "$ROOT/crates/love-lite/UPSTREAM.md"
! grep -Fiq 'experimental 16-megapixel' "$ROOT/crates/love-lite/src/lib.rs"

# Ordinary game launchers keep using PortMaster's installed LÖVE runtime. The
# APP-specific executable and tuning variables must not leak into shared code
# or any other built launcher.
grep -Fq 'runtime latest-love' "$ROOT/_kit/portmaster_common.sh"
! grep -Fq 'sort -V' "$ROOT/_kit/portmaster_common.sh"
! grep -Fq 'love.aarch64' "$ROOT/_kit/portmaster_common.sh"
for launcher in "$ROOT"/ports/*/dist/*.sh; do
  case "$launcher" in */appmanager/*) continue ;; esac
  ! grep -Eq 'LOVE_LITE_|love\.aarch64' "$launcher"
done

echo "appmanager UI runtime scope tests: PASS"
