#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cargo build --quiet --manifest-path "$ROOT/Cargo.toml" -p appmanager-cli
APPMANAGER_CLI="$ROOT/target/debug/appmanager-cli"
LAUNCHER="$ROOT/ports/appmanager/src/launcher.sh"

run_health() {
  local name=$1
  shift
  mkdir -p "$TMP/$name/source" "$TMP/$name/app/state"
  cp -R "$ROOT/config" "$TMP/$name/app/config"
  env "$@" "$APPMANAGER_CLI" --config-dir "$TMP/$name/app/config" launcher-session \
      --source-dir "$TMP/$name/source" --launcher "$LAUNCHER" --app-root "$TMP/$name/app" \
      -- --health-check
}

trimui=$(run_health trimui env CFW_NAME=TrimUI CFW_VERSION=1.3.0 DEVICE=smart-pro \
  PAM_NATIVE_LAUNCHER_OVERRIDE='/mnt/SDCARD/Roms/PORTS/APP Manager.sh')
case "$trimui" in
  missing$'\t\t'tested$'\t/mnt/SDCARD/Apps/PortMaster/PortMaster') ;;
  *) echo "native TrimUI profile mismatch: $trimui" >&2; exit 1 ;;
esac

generic=$(run_health generic env -u CFW_NAME)
case "$generic" in
  missing$'\t\t'unknown-path$'\t') ;;
  *) echo "native generic gate mismatch: $generic" >&2; exit 1 ;;
esac

target="$TMP/generic-confirmed/PortMaster"
confirmed=$(run_health generic-confirmed env -u CFW_NAME PAM_PORTMASTER_DIR_OVERRIDE="$target")
case "$confirmed" in
  missing$'\t\t'unsupported-known$'\t'"$target") ;;
  *) echo "native explicit target mismatch: $confirmed" >&2; exit 1 ;;
esac

mkdir -p "$TMP/env/source" "$TMP/env/app/state"
cp -R "$ROOT/config" "$TMP/env/app/config"
env CFW_NAME=CrossMix CFW_VERSION=1.3.0 DEVICE=smart-pro \
  PAM_NATIVE_LAUNCHER_OVERRIDE='/mnt/SDCARD/Roms/PORTS/APP Manager.sh' \
  "$APPMANAGER_CLI" --config-dir "$TMP/env/app/config" launcher-session \
  --source-dir "$TMP/env/source" --launcher "$LAUNCHER" --app-root "$TMP/env/app" -- --write-env
python3 - "$TMP/env/app/state/env.json" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as handle:
    env = json.load(handle)
assert env["param_device"] == "trimui"
assert env["device_name"] == "TrimUI Smart Pro"
assert env["device_manufacturer"] == "TrimUI"
assert env["device_submodel"] == "smart-pro"
assert env["system_name"] == "CrossMix"
assert env["system_version"] == "1.3.0"
assert env["directory"] == "/mnt/SDCARD/Data"
assert env["gamedirs_dir"] == "/mnt/SDCARD/Data/ports"
assert env["images_dir"] == "/mnt/SDCARD/Roms/Imgs/PORTS"
assert env["portmaster_frontend_kind"] == "trimui"
assert env["target_confirmed"] == "1"
assert env["display_width"] == "1280"
assert env["display_height"] == "720"
assert env["analog_sticks"] == "2"
assert env["capability_install_portmaster"] is True
assert env["capability_update_portmaster"] is True
assert env["capability_repair_runtimes"] is True
PY

# The remote configuration is not merely validated: resolved display/input,
# capability and release-route fields must reach the real launcher contract.
python3 - "$ROOT/config/config.json" "$ROOT/config/platforms/trimui.json" "$TMP/env/app/state/device-config" <<'PY'
import hashlib, json, pathlib, sys

with open(sys.argv[1], encoding="utf-8") as handle:
    root = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    detail = json.load(handle)
output = pathlib.Path(sys.argv[3])
(output / "platforms").mkdir(parents=True)
root["config_version"] = "1.1.1"
detail["config_version"] = "1.1.1"
detail["display"].update(default_width=1024, default_height=768)
detail["input"]["analog_sticks"] = 0
detail["capabilities"].update(
    install_portmaster=False, update_portmaster=False, repair_runtimes=False)
root["sources"]["endpoints"]["fixture_portmaster"] = \
    "https://github.com/example/PortMaster-GUI/releases/latest/download/version.json"
root["sources"]["release_routes"]["fixture"] = {
    "manifest": "fixture_portmaster", "archive_name": "PortMaster.zip",
    "channel": "stable", "checksum": "md5_from_manifest", "install_allowed": False,
}
detail["source_route"] = "fixture"
detail_raw = (json.dumps(detail, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
(output / "platforms/trimui.json").write_bytes(detail_raw)
root["platforms"]["trimui"]["sha256"] = hashlib.sha256(detail_raw).hexdigest()
(output / "config.json").write_text(
    json.dumps(root, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY

env CFW_NAME=TrimUI \
  PAM_NATIVE_LAUNCHER_OVERRIDE='/mnt/SDCARD/Roms/PORTS/APP Manager.sh' \
  "$APPMANAGER_CLI" --config-dir "$TMP/env/app/config" launcher-session \
  --source-dir "$TMP/env/source" --launcher "$LAUNCHER" --app-root "$TMP/env/app" -- --write-env
python3 - "$TMP/env/app/state/env.json" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as handle:
    env = json.load(handle)
assert env["display_width"] == "1024"
assert env["display_height"] == "768"
assert env["analog_sticks"] == "0"
assert env["capability_install_portmaster"] is False
assert env["capability_update_portmaster"] is False
assert env["capability_repair_runtimes"] is False
assert env["portmaster_release_manifest_url"] == "https://github.com/example/PortMaster-GUI/releases/latest/download/version.json"
assert env["portmaster_release_archive_url"] == "https://github.com/example/PortMaster-GUI/releases/latest/download/PortMaster.zip"
assert env["portmaster_release_archive_name"] == "PortMaster.zip"
assert env["portmaster_release_install_allowed"] is False
assert env["health_contract"] == "portkit.health.v1"
assert "required_file" in env["health_required"]
PY

if env CFW_NAME=TrimUI \
  PAM_NATIVE_LAUNCHER_OVERRIDE='/mnt/SDCARD/Roms/PORTS/APP Manager.sh' \
  "$APPMANAGER_CLI" --config-dir "$TMP/env/app/config" launcher-session \
  --source-dir "$TMP/env/source" --launcher "$LAUNCHER" --app-root "$TMP/env/app" -- --write-install-plan >/dev/null; then
  echo "native install capability was not enforced" >&2
  exit 1
fi

# The production launcher must generate the install plan from the same
# native device configuration, without consulting its legacy platform table.
mkdir -p "$TMP/plan/source" "$TMP/plan/app/state"
cp -R "$ROOT/config" "$TMP/plan/app/config"
env CFW_NAME=TrimUI \
  PAM_NATIVE_LAUNCHER_OVERRIDE='/mnt/SDCARD/Roms/PORTS/APP Manager.sh' \
  "$APPMANAGER_CLI" --config-dir "$TMP/plan/app/config" launcher-session \
  --source-dir "$TMP/plan/source" --launcher "$LAUNCHER" --app-root "$TMP/plan/app" -- --write-install-plan > "$TMP/plan/result.tsv"
grep -Fxq $'device\ttrimui' "$TMP/plan/result.tsv"
grep -Fxq $'target\t/mnt/SDCARD/Apps/PortMaster/PortMaster' "$TMP/plan/result.tsv"
grep -Fxq $'frontend_map\ttrimui/PortMaster.txt=launch.sh,trimui/config.json=config.json,trimui/icon.png=icon.png' "$TMP/plan/result.tsv"

echo "appmanager native profile tests: PASS"
