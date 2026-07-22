#!/usr/bin/env bash
set -euo pipefail
export PAM_TOOL_MODE=system # Host fixtures run on macOS, not the packaged aarch64 tools.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/target/debug/appmanager-cli"
TMP="$(mktemp -d)"
cleanup() {
  local rc=$?
  if [ "$rc" != 0 ]; then
    find "$TMP" -type f \( -name 'validation-result.tsv' -o -name 'log.txt' -o -name 'pending-install.tsv' \) | while read -r file; do
      echo "--- $file" >&2
      sed -n '1,240p' "$file" >&2
    done
  fi
  if [ "${KEEP_TMP:-0}" = "1" ]; then echo "kept fixture: $TMP" >&2; return; fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

cargo build --quiet --manifest-path "$ROOT/Cargo.toml" -p appmanager-cli -p portkit-cli
mkdir -p "$TMP/archive/PortMaster/pylibs-src" "$TMP/archive/PortMaster/miniloong" \
  "$TMP/app/bin" "$TMP/app/love_ui"
cp -R "$ROOT/config" "$TMP/app/config"
printf 'new-control\n' > "$TMP/archive/PortMaster/control.txt"
printf 'new-device\n' > "$TMP/archive/PortMaster/device_info.txt"
printf 'new-funcs\n' > "$TMP/archive/PortMaster/funcs.txt"
printf "PORTMASTER_VERSION = '2026.07'\n" > "$TMP/archive/PortMaster/pugwash"
printf '#!/bin/sh\nexit 0\n' > "$TMP/archive/PortMaster/PortMaster.sh"
printf '#!/bin/sh\nexit 0\n' > "$TMP/archive/PortMaster/miniloong/PortMaster.txt"
chmod +x "$TMP/archive/PortMaster/PortMaster.sh" "$TMP/archive/PortMaster/miniloong/PortMaster.txt"
printf 'new-core\n' > "$TMP/archive/PortMaster/core.txt"
printf 'module\n' > "$TMP/archive/PortMaster/pylibs-src/module.py"
(cd "$TMP/archive/PortMaster/pylibs-src" && zip -q ../pylibs.zip module.py)
rm -rf "$TMP/archive/PortMaster/pylibs-src"
(cd "$TMP/archive" && zip -qr "$TMP/PortMaster.zip" PortMaster)
install_case() {
  local name=$1 mode=$2 root device scripts target
  root="$TMP/$name"; device="$root/device"
  scripts="$device/mnt/sdcard/roms/ports"; target="$scripts/PortMaster"
  mkdir -p "$device/loong" "$target/libs" "$root/state" "$root/trash"
  printf '1.0\n' > "$device/loong/loong_version"
  printf '#!/bin/sh\nexit 0\n' > "$scripts/APP Manager.sh"
  printf 'runtime-sentinel\n' > "$target/libs/keep.squashfs"
  printf 'hsqs-python-runtime\n' > "$target/libs/python_3.11.squashfs"
  if [ "$mode" = update ]; then
    printf 'old-control\n' > "$target/control.txt"
    printf 'old-device\n' > "$target/device_info.txt"
    printf 'old-funcs\n' > "$target/funcs.txt"
    printf "PORTMASTER_VERSION = '2026.06'\n" > "$target/pugwash"
    printf 'old-core\n' > "$target/old.txt"
    printf 'old-launcher\n' > "$scripts/PortMaster.sh"
  fi
  "$CLI" --config-dir "$ROOT/config" install-portmaster \
    --archive "$TMP/PortMaster.zip" --launcher "$scripts/APP Manager.sh" \
    --app-state "$root/state" --trash "$root/trash" --root "$device" >/dev/null
  grep -Fqx $'version\t1' "$root/state/pending-install.tsv"
}

validate_case() {
  local name=$1 interrupted=${2:-0} fail_restore_after=${3:-0} root device scripts target
  root="$TMP/$name"; device="$root/device"
  scripts="$device/mnt/sdcard/roms/ports"; target="$scripts/PortMaster"
  PAM_SOURCE_DIR="$scripts" PAM_APP_ROOT_OVERRIDE="$TMP/app" \
    PAM_STATE_DIR_OVERRIDE="$root/state" PAM_NATIVE_ROOT="$device" \
    PAM_NATIVE_LAUNCHER_OVERRIDE="$scripts/APP Manager.sh" \
    PAM_APPMANAGER_CLI_BIN_OVERRIDE="$CLI" \
    PAM_PORTKIT_BIN_OVERRIDE="$ROOT/target/debug/portkit" \
    PAM_PORTMASTER_DIR_OVERRIDE="$target" \
    PAM_DIRECTORY_OVERRIDE="${root#/}/data" \
    PAM_TEST_INTERRUPT_VALIDATION="$interrupted" \
    PAM_TEST_FAIL_RESTORE_AFTER="$fail_restore_after" \
    bash "$ROOT/ports/appmanager/src/launcher.sh" --validate-pending
}

target_for() { printf '%s/device/mnt/sdcard/roms/ports/PortMaster' "$TMP/$1"; }
scripts_for() { printf '%s/device/mnt/sdcard/roms/ports' "$TMP/$1"; }

install_case success install
validate_case success
grep -Fq $'1\tvalid\t' "$TMP/success/state/validation-result.tsv"
[ ! -e "$TMP/success/state/pending-install.tsv" ]
[ ! -e "$(target_for success)/.appmanager-rollback" ]
grep -Fxq new-core "$(target_for success)/core.txt"
grep -Fxq runtime-sentinel "$(target_for success)/libs/keep.squashfs"

install_case rollback update
rm -f "$(target_for rollback)/funcs.txt"
validate_case rollback || true
grep -Fq $'1\trestored\t' "$TMP/rollback/state/validation-result.tsv"
grep -Fxq old-core "$(target_for rollback)/old.txt"
grep -Fxq old-launcher "$(scripts_for rollback)/PortMaster.sh"
grep -Fxq runtime-sentinel "$(target_for rollback)/libs/keep.squashfs"

install_case first-failure install
rm -f "$(target_for first-failure)/funcs.txt"
validate_case first-failure || true
grep -Fq $'1\tno-usable\t' "$TMP/first-failure/state/validation-result.tsv"
[ ! -e "$(target_for first-failure)/control.txt" ]
grep -Fxq runtime-sentinel "$(target_for first-failure)/libs/keep.squashfs"

install_case interrupted update
validate_case interrupted 1 || true
grep -Fq $'1\tinterrupted\t' "$TMP/interrupted/state/validation-result.tsv"
[ -s "$TMP/interrupted/state/pending-install.tsv" ]
grep -Fxq new-core "$(target_for interrupted)/core.txt"

install_case launcher-missing update
rm -f "$(scripts_for launcher-missing)/PortMaster.sh"
validate_case launcher-missing || true
grep -Fq $'1\trestored\t' "$TMP/launcher-missing/state/validation-result.tsv"
grep -Fxq old-core "$(target_for launcher-missing)/old.txt"
grep -Fxq old-launcher "$(scripts_for launcher-missing)/PortMaster.sh"

install_case manifest-truncated update
head -n 1 "$TMP/manifest-truncated/state/pending-manifest.tsv" > "$TMP/manifest-truncated/state/manifest.tmp"
mv "$TMP/manifest-truncated/state/manifest.tmp" "$TMP/manifest-truncated/state/pending-manifest.tsv"
rm -f "$(target_for manifest-truncated)/pylibs.zip"
validate_case manifest-truncated || true
grep -Fq $'1\trestored\t' "$TMP/manifest-truncated/state/validation-result.tsv"
grep -Fxq old-core "$(target_for manifest-truncated)/old.txt"

install_case mode-missing update
sed '/^mode\t/d' "$TMP/mode-missing/state/pending-install.tsv" > "$TMP/mode-missing/state/pending.tmp"
mv "$TMP/mode-missing/state/pending.tmp" "$TMP/mode-missing/state/pending-install.tsv"
rm -f "$(target_for mode-missing)/funcs.txt"
validate_case mode-missing || true
grep -Fq $'1\trestored\t' "$TMP/mode-missing/state/validation-result.tsv"
grep -Fxq old-core "$(target_for mode-missing)/old.txt"

install_case first-no-manifest install
rm -f "$TMP/first-no-manifest/state/pending-manifest.tsv"
validate_case first-no-manifest || true
grep -Fq $'1\tno-usable\t' "$TMP/first-no-manifest/state/validation-result.tsv"
[ ! -e "$(target_for first-no-manifest)/control.txt" ]
grep -Fxq runtime-sentinel "$(target_for first-no-manifest)/libs/keep.squashfs"

# Rollback is restartable after a power loss during restoration.
install_case restore-retry update
rm -f "$(target_for restore-retry)/funcs.txt"
validate_case restore-retry 0 1 || true
grep -Fq $'1\tinterrupted\t' "$TMP/restore-retry/state/validation-result.tsv"
[ -f "$(target_for restore-retry)/.appmanager-rollback/restoring" ]
validate_case restore-retry || true
grep -Fq $'1\trestored\t' "$TMP/restore-retry/state/validation-result.tsv"
grep -Fxq old-core "$(target_for restore-retry)/old.txt"

# Tampered rollback metadata blocks destructive recovery and preserves both copies.
install_case rollback-metadata update
printf 'tampered\n' >> "$(target_for rollback-metadata)/.appmanager-rollback/expected-tops.tsv"
rm -f "$(target_for rollback-metadata)/funcs.txt"
validate_case rollback-metadata || true
grep -Fq $'1\tinterrupted\t' "$TMP/rollback-metadata/state/validation-result.tsv"
grep -Fxq new-core "$(target_for rollback-metadata)/core.txt"
grep -Fxq old-core "$(target_for rollback-metadata)/.appmanager-rollback/core/old.txt"

# A recycled PID from an unrelated process is stale and must not block validation.
install_case validation-stale update
mkdir "$TMP/validation-stale/state/validation.lock"
cat > "$TMP/validation-stale/state/validation.lock/owner.tsv" <<EOF
version	1
token	stale
pid	$$
mode	--validate-pending
EOF
mkdir -p "$TMP/proc-stale/$$"
printf 'bash\0unrelated-script.sh\0--validate-pending\0' > "$TMP/proc-stale/$$/cmdline"
PAM_PROC_ROOT="$TMP/proc-stale" validate_case validation-stale
grep -Fq $'1\tvalid\t' "$TMP/validation-stale/state/validation-result.tsv"

# A live validator owns the lock and a contender performs no mutation.
install_case validation-locked update
cat > "$TMP/validation-locked/state/apply-helper.sh" <<'HELPER'
#!/bin/sh
trap 'exit 0' TERM INT
while :; do sleep 1; done
HELPER
chmod +x "$TMP/validation-locked/state/apply-helper.sh"
"$TMP/validation-locked/state/apply-helper.sh" --validate-pending &
validation_pid=$!
mkdir "$TMP/validation-locked/state/validation.lock"
cat > "$TMP/validation-locked/state/validation.lock/owner.tsv" <<EOF
version	1
token	live
pid	$validation_pid
mode	--validate-pending
EOF
mkdir -p "$TMP/proc-live/$validation_pid"
printf 'sh\0%s\0--validate-pending\0' \
  "$TMP/validation-locked/state/apply-helper.sh" > "$TMP/proc-live/$validation_pid/cmdline"
PAM_PROC_ROOT="$TMP/proc-live" validate_case validation-locked || true
grep -Fq $'1\tchecking\tAnother validation process is still running' \
  "$TMP/validation-locked/state/validation-result.tsv"
[ -s "$TMP/validation-locked/state/pending-install.tsv" ]
kill "$validation_pid" 2>/dev/null || true
wait "$validation_pid" 2>/dev/null || true
rm -rf "$TMP/validation-locked/state/validation.lock"
validate_case validation-locked
grep -Fq $'1\tvalid\t' "$TMP/validation-locked/state/validation-result.tsv"

echo "appmanager pending validation tests: PASS"
