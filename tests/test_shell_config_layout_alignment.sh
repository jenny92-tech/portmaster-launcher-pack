#!/usr/bin/env bash
# Alignment guard: device-layout facts must agree between the declarative
# device config (config/) and the shell launch chain (_kit/). The two worlds
# cannot share code (game launchers must be self-contained), so this test
# fails whenever either side drifts — e.g. the trimui paths.images bug where
# config said Roms/Imgs/PORTS while the firmware and _kit used Imgs/PORTS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cargo build --quiet --manifest-path "$ROOT/Cargo.toml" -p appmanager-cli -p portkit-launcher
CLI="$ROOT/target/debug/appmanager-cli"
HELPER="$ROOT/target/debug/portkit-launcher"

fail() { echo "layout alignment FAILED: $1" >&2; exit 1; }

# --- TrimUI images: engine-resolved config path vs shell-computed path ------
mkdir -p "$TMP/env/source" "$TMP/env/app/state"
cp -R "$ROOT/config" "$TMP/env/app/config"
env CFW_NAME=TrimUI CFW_VERSION=1.3.0 DEVICE=smart-pro \
  PAM_NATIVE_LAUNCHER_OVERRIDE='/mnt/SDCARD/Roms/PORTS/APP Manager.sh' \
  "$CLI" --config-dir "$TMP/env/app/config" launcher-session \
  --source-dir "$TMP/env/source" --launcher "$ROOT/ports/appmanager/src/launcher.sh" \
  --app-root "$TMP/env/app" -- --write-env >/dev/null
cfg_images=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["images_dir"])' "$TMP/env/app/state/env.json")

mkdir -p "$TMP/card/Roms/PORTS" "$TMP/card/Emus/PORTS"
: > "$TMP/card/Emus/PORTS/config.json"
probed=$("$HELPER" artwork probe --script-dir "$TMP/card/Roms/PORTS")
[ -n "$probed" ] || fail "helper does not know the TrimUI image dir"
cfg_rel="${cfg_images#/mnt/SDCARD}"
sh_rel="${probed#"$TMP/card"}"
[ "$cfg_rel" = "$sh_rel" ] || fail "trimui images: config=$cfg_rel helper=$sh_rel"

# --- MiniLoong images: declared config strategy vs shell-computed path ------
python3 - "$ROOT/config/platforms/miniloong.json" <<'PY'
import json, sys
paths = json.load(open(sys.argv[1]))["paths"]
images = paths["images"]
assert images == {"strategy": "relative_to", "base": "scripts", "suffix": "images"}, \
    f"miniloong images strategy drifted: {images}"
assert paths["scripts"] == {"strategy": "launcher_dir"}, \
    f"miniloong scripts strategy drifted: {paths['scripts']}"
PY

mkdir -p "$TMP/ports"
: > "$TMP/loong-version"
probed=$(PORTMASTER_LOONG_VERSION_FILE="$TMP/loong-version" \
  "$HELPER" artwork probe --script-dir "$TMP/ports")
[ -n "$probed" ] || fail "helper does not know the MiniLoong image dir"
sh_rel="${probed#"$TMP/ports"}"
[ "$sh_rel" = "/images" ] || fail "miniloong images: helper=$sh_rel, config declares relative_to scripts + images"

# --- MiniLoong controlfolder: config literal must stay discoverable ---------
core=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["paths"]["portmaster_core"]["value"])' \
  "$ROOT/config/platforms/miniloong.json")
grep -Fq "$core" "$ROOT/_kit/portmaster_bootstrap.sh" \
  || fail "miniloong portmaster_core $core missing from portmaster_bootstrap.sh candidates"

echo "shell/config layout alignment tests: PASS"
