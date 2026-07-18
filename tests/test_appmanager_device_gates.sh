#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/app/love_ui" "$TMP/source" "$TMP/state"

mkdir -p "$TMP/loong" "$TMP/trimui" "$TMP/muos" "$TMP/spruce"
printf '1.0\n' > "$TMP/loong/loong_version"
printf 'knulli\n' > "$TMP/knulli-version"
printf 'batocera\n' > "$TMP/batocera-version"
mini=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/mini-state" \
  PAM_LOONG_VERSION_FILE="$TMP/loong/loong_version" bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$mini" in missing$'\t\t'tested$'\t/mnt/sdcard/roms/ports/PortMaster') ;; *) echo "bad MiniLoong profile: $mini" >&2; exit 1 ;; esac

trim=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/trim-state" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/trimui" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$trim" in missing$'\t\t'tested$'\t/mnt/SDCARD/Apps/PortMaster/PortMaster') ;; *) echo "bad TrimUI profile: $trim" >&2; exit 1 ;; esac

muos=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/muos-state" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_MUOS_ROOT="$TMP/muos" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$muos" in missing$'\t\t'official-untested$'\t/mnt/mmc/MUOS/PortMaster') ;; *) echo "bad muOS profile: $muos" >&2; exit 1 ;; esac

knulli=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/knulli-state" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_MUOS_ROOT="$TMP/no-muos" \
  PAM_KNULLI_MARKER="$TMP/knulli-version" bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$knulli" in missing$'\t\t'official-untested$'\t/userdata/system/.local/share/PortMaster') ;; *) echo "bad Knulli profile: $knulli" >&2; exit 1 ;; esac

batocera=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/batocera-state" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_MUOS_ROOT="$TMP/no-muos" \
  PAM_KNULLI_MARKER="$TMP/no-knulli" PAM_BATOCERA_VERSION_FILE="$TMP/batocera-version" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$batocera" in missing$'\t\t'official-untested$'\t/userdata/system/.local/share/PortMaster') ;; *) echo "bad Batocera profile: $batocera" >&2; exit 1 ;; esac

miyoo=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/miyoo-state" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_MUOS_ROOT="$TMP/no-muos" \
  PAM_KNULLI_MARKER="$TMP/no-knulli" PAM_BATOCERA_VERSION_FILE="$TMP/no-batocera" \
  PAM_SPRUCE_ROOT="$TMP/spruce" bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$miyoo" in missing$'\t\t'official-untested$'\t/mnt/sdcard/Roms/.portmaster/PortMaster') ;; *) echo "bad Miyoo profile: $miyoo" >&2; exit 1 ;; esac

PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/mini-env" \
  PAM_LOONG_VERSION_FILE="$TMP/loong/loong_version" bash "$ROOT/ports/appmanager/src/launcher.sh" --scan
PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/trim-env" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/trimui" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --scan
PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/muos-env" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_MUOS_ROOT="$TMP/muos" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --scan
PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/miyoo-env" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_MUOS_ROOT="$TMP/no-muos" \
  PAM_KNULLI_MARKER="$TMP/no-knulli" PAM_BATOCERA_VERSION_FILE="$TMP/no-batocera" \
  PAM_SPRUCE_ROOT="$TMP/spruce" bash "$ROOT/ports/appmanager/src/launcher.sh" --scan
grep -Fq '"portmaster_release_channel": "miniloong-custom"' "$TMP/mini-env/env.json"
grep -Fq '"portmaster_release_channel": "official"' "$TMP/trim-env/env.json"
grep -Fq '"portmaster_frontend_kind": "trimui"' "$TMP/trim-env/env.json"
grep -Fq '"portmaster_frontend_dir": "/mnt/SDCARD/Apps/PortMaster"' "$TMP/trim-env/env.json"
grep -Fq '"param_device": "muos"' "$TMP/muos-env/env.json"
grep -Fq '"gamedirs_dir": "/mnt/mmc/ports"' "$TMP/muos-env/env.json"
grep -Fq '"portmaster_frontend_dir": "/roms/ports/PortMaster"' "$TMP/muos-env/env.json"
grep -Fq '"param_device": "miyoo"' "$TMP/miyoo-env/env.json"
grep -Fq '"gamedirs_dir": "/mnt/sdcard/Roms/PORTS64"' "$TMP/miyoo-env/env.json"

# Bootstrap produces a complete normalized install plan locally for every
# supported device. The branch-maintained installer never has to rediscover
# firmware identity or guess any destination path.
assert_plan() {
  local output=$1 device=$2 target=$3 frontend=$4 names=$5 map=$6
  grep -Fqx $'schema\t1' <<< "$output"
  grep -Fqx $'device\t'"$device" <<< "$output"
  grep -Fqx $'target\t'"$target" <<< "$output"
  grep -Fqx $'frontend_dir\t'"$frontend" <<< "$output"
  grep -Fqx $'frontend_names\t'"$names" <<< "$output"
  grep -Fqx $'frontend_map\t'"$map" <<< "$output"
}
mini_plan=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/mini-plan" \
  PAM_LOONG_VERSION_FILE="$TMP/loong/loong_version" bash "$ROOT/ports/appmanager/src/launcher.sh" --write-install-plan)
assert_plan "$mini_plan" miniloong /mnt/sdcard/roms/ports/PortMaster "$TMP/source" PortMaster.sh 'miniloong/PortMaster.txt=PortMaster.sh'
trim_plan=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/trim-plan" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/trimui" bash "$ROOT/ports/appmanager/src/launcher.sh" --write-install-plan)
assert_plan "$trim_plan" trimui /mnt/SDCARD/Apps/PortMaster/PortMaster /mnt/SDCARD/Apps/PortMaster \
  'launch.sh,config.json,icon.png' 'trimui/PortMaster.txt=launch.sh,trimui/config.json=config.json,trimui/icon.png=icon.png'
muos_plan=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/muos-plan" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_MUOS_ROOT="$TMP/muos" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --write-install-plan)
assert_plan "$muos_plan" muos /mnt/mmc/MUOS/PortMaster /roms/ports/PortMaster control.txt 'muos/control.txt=control.txt'
knulli_plan=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/knulli-plan" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_MUOS_ROOT="$TMP/no-muos" \
  PAM_KNULLI_MARKER="$TMP/knulli-version" bash "$ROOT/ports/appmanager/src/launcher.sh" --write-install-plan)
assert_plan "$knulli_plan" knulli /userdata/system/.local/share/PortMaster "$TMP/source" PortMaster.sh 'PortMaster.sh=PortMaster.sh'
batocera_plan=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/batocera-plan" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_MUOS_ROOT="$TMP/no-muos" \
  PAM_KNULLI_MARKER="$TMP/no-knulli" PAM_BATOCERA_VERSION_FILE="$TMP/batocera-version" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --write-install-plan)
assert_plan "$batocera_plan" batocera /userdata/system/.local/share/PortMaster "$TMP/source" PortMaster.sh 'PortMaster.sh=PortMaster.sh'
miyoo_plan=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/miyoo-plan" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_MUOS_ROOT="$TMP/no-muos" \
  PAM_KNULLI_MARKER="$TMP/no-knulli" PAM_BATOCERA_VERSION_FILE="$TMP/no-batocera" PAM_SPRUCE_ROOT="$TMP/spruce" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --write-install-plan)
assert_plan "$miyoo_plan" miyoo /mnt/sdcard/Roms/.portmaster/PortMaster /root/.local/share/PortMaster control.txt 'miyoo/control.txt=control.txt'
generic_plan=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/generic-plan" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_MUOS_ROOT="$TMP/no-muos" \
  PAM_KNULLI_MARKER="$TMP/no-knulli" PAM_BATOCERA_VERSION_FILE="$TMP/no-batocera" PAM_SPRUCE_ROOT="$TMP/no-spruce" \
  PAM_PORTMASTER_DIR_OVERRIDE="$TMP/generic/PortMaster" bash "$ROOT/ports/appmanager/src/launcher.sh" --write-install-plan)
assert_plan "$generic_plan" generic "$TMP/generic/PortMaster" "$TMP/source" PortMaster.sh 'PortMaster.sh=PortMaster.sh'

official="$TMP/official/PortMaster"
mkdir -p "$official"
printf 'controlfolder=%s\n' "$official" > "$official/control.txt"
off=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/off-state" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_PORTMASTER_DIR_OVERRIDE="$official" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$off" in damaged$'\t\t'unsupported-known$'\t'"$official") ;; *) echo "bad unrecognized installed profile: $off" >&2; exit 1 ;; esac

known="$TMP/known/PortMaster"
known_result=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/known-state" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_PORTMASTER_DIR_OVERRIDE="$known" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$known_result" in missing$'\t\t'unsupported-known$'\t'"$known") ;; *) echo "bad known unsupported profile: $known_result" >&2; exit 1 ;; esac

unknown=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/unknown-state" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$unknown" in missing$'\t\t'unknown-path$'\t') ;; *) echo "bad unknown profile: $unknown" >&2; exit 1 ;; esac

run_rejected_plan() {
  local name=$1 class=$2 target=$3 plan=$4 state
  state="$TMP/$name-state"
  mkdir -p "$state"
  printf '%b' "$plan" > "$state/plan.txt"
  PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$state" \
    PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" \
    PAM_PORTMASTER_DIR_OVERRIDE="$target" PAM_DEVICE_CLASS_OVERRIDE="$class" \
    PAM_TARGET_CONFIRMED_OVERRIDE="$([ "$class" = unknown-path ] && echo 0 || echo 1)" \
    bash "$ROOT/ports/appmanager/src/launcher.sh" --apply-plan
}

run_rejected_plan official-no-ack unsupported-known "$official" 'INSTALL_PORTMASTER\tstable\n'
grep -Fq $'FAIL\tportmaster\tdevice-acks-required' "$TMP/official-no-ack-state/result.txt"
run_rejected_plan unsupported-one-ack unsupported-known "$known" 'ACK_DEVICE_RISK\tunsupported-known\nINSTALL_PORTMASTER\tstable\n'
grep -Fq $'FAIL\tportmaster\tdevice-acks-required' "$TMP/unsupported-one-ack-state/result.txt"
run_rejected_plan unknown-path unknown-path "$TMP/guessed" 'INSTALL_PORTMASTER\tstable\n'
grep -Fq $'FAIL\tportmaster\tunknown-target' "$TMP/unknown-path-state/result.txt"

grep -Fq 'id="risk:modify"' "$ROOT/ports/appmanager/love/app_environment.lua"
grep -Fq 'id="risk:support"' "$ROOT/ports/appmanager/love/app_environment.lua"
grep -Fq 'disabled=not ready' "$ROOT/ports/appmanager/love/app_environment.lua"
grep -Fq 'batch_size=5' "$ROOT/ports/appmanager/src/launcher.sh"

echo "appmanager device gate tests: PASS"
