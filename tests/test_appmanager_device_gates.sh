#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/app/love_ui" "$TMP/source" "$TMP/state"

mkdir -p "$TMP/loong" "$TMP/trimui"
printf '1.0\n' > "$TMP/loong/loong_version"
mini=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/mini-state" \
  PAM_LOONG_VERSION_FILE="$TMP/loong/loong_version" bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$mini" in missing$'\t\t'tested$'\t/mnt/sdcard/roms/ports/PortMaster') ;; *) echo "bad MiniLoong profile: $mini" >&2; exit 1 ;; esac

trim=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/trim-state" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/trimui" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$trim" in missing$'\t\t'tested$'\t/mnt/SDCARD/Data/ports/PortMaster') ;; *) echo "bad TrimUI profile: $trim" >&2; exit 1 ;; esac

official="$TMP/official/PortMaster"
mkdir -p "$official"
printf 'controlfolder=%s\n' "$official" > "$official/control.txt"
off=$(PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/off-state" \
  PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" PAM_PORTMASTER_DIR_OVERRIDE="$official" \
  bash "$ROOT/ports/appmanager/src/launcher.sh" --health-check)
case "$off" in damaged$'\t\t'official-untested$'\t'"$official") ;; *) echo "bad official profile: $off" >&2; exit 1 ;; esac

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

run_rejected_plan official-no-ack official-untested "$official" 'INSTALL_PORTMASTER\tstable\n'
grep -Fq $'FAIL\tportmaster\tdevice-ack-required' "$TMP/official-no-ack-state/result.txt"
run_rejected_plan unsupported-one-ack unsupported-known "$known" 'ACK_DEVICE_RISK\tunsupported-known\nINSTALL_PORTMASTER\tstable\n'
grep -Fq $'FAIL\tportmaster\tdevice-acks-required' "$TMP/unsupported-one-ack-state/result.txt"
run_rejected_plan unknown-path unknown-path "$TMP/guessed" 'INSTALL_PORTMASTER\tstable\n'
grep -Fq $'FAIL\tportmaster\tunknown-target' "$TMP/unknown-path-state/result.txt"

grep -Fq 'id="risk:modify"' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'id="risk:support"' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'disabled=not ready' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'batch_size=5' "$ROOT/ports/appmanager/src/launcher.sh"

echo "appmanager device gate tests: PASS"
