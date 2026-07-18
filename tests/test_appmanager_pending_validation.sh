#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUI_ROOT="${PAM_GUI_ROOT_OVERRIDE:-$ROOT/../PortMaster-GUI}"
INSTALLER="$GUI_ROOT/tools/portappmanager-installer.sh"
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

mkdir -p "$TMP/source/PortMaster/pylibs-src" "$TMP/source/PortMaster/trimui" "$TMP/source/PortMaster/miniloong" \
  "$TMP/source/PortMaster/muos" "$TMP/source/PortMaster/batocera" "$TMP/app/bin" "$TMP/app/love_ui"
mkdir -p "$TMP/loong"
printf '1.0\n' > "$TMP/loong/loong_version"
printf 'new-control\n' > "$TMP/source/PortMaster/control.txt"
printf 'new-device\n' > "$TMP/source/PortMaster/device_info.txt"
printf 'new-funcs\n' > "$TMP/source/PortMaster/funcs.txt"
printf "PORTMASTER_VERSION = '2026.07'\n" > "$TMP/source/PortMaster/pugwash"
printf '#!/bin/sh\nexit 0\n' > "$TMP/source/PortMaster/PortMaster.sh"
printf '#!/bin/sh\nexit 0\n' > "$TMP/source/PortMaster/miniloong/PortMaster.txt"
printf 'new-core\n' > "$TMP/source/PortMaster/core.txt"
printf 'trimui-control\n' > "$TMP/source/PortMaster/trimui/control.txt"
printf '#!/bin/sh\nexit 0\n' > "$TMP/source/PortMaster/trimui/PortMaster.txt"
printf '{"label":"PortMaster"}\n' > "$TMP/source/PortMaster/trimui/config.json"
printf 'trimui-icon\n' > "$TMP/source/PortMaster/trimui/icon.png"
printf 'muos-control\n' > "$TMP/source/PortMaster/muos/control.txt"
printf '#!/bin/sh\nexit 0\n' > "$TMP/source/PortMaster/muos/PortMaster.txt"
printf 'batocera-control\n' > "$TMP/source/PortMaster/batocera/control.txt"
printf 'generic-tasksetter\n' > "$TMP/source/PortMaster/tasksetter"
printf 'module\n' > "$TMP/source/PortMaster/pylibs-src/module.py"
(cd "$TMP/source/PortMaster/pylibs-src" && zip -q ../pylibs.zip module.py)
rm -rf "$TMP/source/PortMaster/pylibs-src"
(cd "$TMP/source" && zip -qr "$TMP/PortMaster.zip" PortMaster)
cat > "$TMP/app/bin/sha256sum-portable" <<'SHA'
#!/bin/sh
exec shasum -a 256 "$@"
SHA
cat > "$TMP/app/bin/unzip-portable" <<'UNZIP'
#!/bin/sh
exec unzip "$@"
UNZIP
chmod +x "$TMP/app/bin/sha256sum-portable" "$TMP/app/bin/unzip-portable"

write_plan() {
  local profile=$1 target=$2 scripts=$3 frontend=$4 plan=$5
  local names primary control core map remove empty core_exec frontend_exec
  case "$profile" in
    trimui) names='launch.sh,config.json,icon.png'; primary='launch.sh'; control='trimui/control.txt'; core='-'; map='trimui/PortMaster.txt=launch.sh,trimui/config.json=config.json,trimui/icon.png=icon.png'; remove=1; empty=1; core_exec='-'; frontend_exec='launch.sh' ;;
    muos) names='control.txt'; primary='control.txt'; control='muos/control.txt'; core='muos/PortMaster.txt'; map='muos/control.txt=control.txt'; remove=0; empty=1; core_exec='PortMaster.sh'; frontend_exec='-' ;;
    batocera) names='PortMaster.sh'; primary='PortMaster.sh'; control='batocera/control.txt'; core='-'; map='PortMaster.sh=PortMaster.sh'; remove=1; empty=1; core_exec='-'; frontend_exec='PortMaster.sh' ;;
    miniloong) names='PortMaster.sh'; primary='PortMaster.sh'; control='-'; core='-'; map='miniloong/PortMaster.txt=PortMaster.sh'; remove=0; empty=0; core_exec='PortMaster.sh'; frontend_exec='PortMaster.sh' ;;
  esac
  {
    printf 'schema\t1\ndevice\t%s\ntarget\t%s\nscripts\t%s\nfrontend_dir\t%s\n' "$profile" "$target" "$scripts" "$frontend"
    printf 'frontend_names\t%s\nprimary_frontend\t%s\ncontrol_source\t%s\ncore_launcher_source\t%s\n' "$names" "$primary" "$control" "$core"
    printf 'frontend_map\t%s\nremove_core_launcher\t%s\nempty_tasksetter\t%s\ncore_executable\t%s\nfrontend_executable\t%s\n' "$map" "$remove" "$empty" "$core_exec" "$frontend_exec"
  } > "$plan"
}

install_case() {
  local name=$1 mode=$2 root target
  root="$TMP/$name"; target="$root/PortMaster"
  mkdir -p "$target/libs" "$root/scripts" "$root/state"
  printf 'runtime-sentinel\n' > "$target/libs/keep.squashfs"
  if [ "$mode" = update ]; then
    printf 'old-control\n' > "$target/control.txt"
    printf 'old-device\n' > "$target/device_info.txt"
    printf 'old-funcs\n' > "$target/funcs.txt"
    printf "PORTMASTER_VERSION = '2026.06'\n" > "$target/pugwash"
    printf 'old-core\n' > "$target/old.txt"
    printf 'old-launcher\n' > "$root/scripts/PortMaster.sh"
  fi
  write_plan miniloong "$target" "$root/scripts" "$root/scripts" "$root/install-plan.tsv"
  "$INSTALLER" --archive "$TMP/PortMaster.zip" --plan "$root/install-plan.tsv" \
    --state-dir "$root/state" >/dev/null
}

validate_case() {
  local name=$1 interrupted=${2:-0} fail_restore_after=${3:-0} root
  root="$TMP/$name"
  PAM_SOURCE_DIR="$root/scripts" PAM_APP_ROOT_OVERRIDE="$TMP/app" \
    PAM_STATE_DIR_OVERRIDE="$root/state" PAM_PORTMASTER_DIR_OVERRIDE="$root/PortMaster" \
    PAM_LOONG_VERSION_FILE="$TMP/loong/loong_version" \
    PAM_DIRECTORY_OVERRIDE="${root#/}/data" PAM_TEST_INTERRUPT_VALIDATION="$interrupted" \
    PAM_TEST_FAIL_RESTORE_AFTER="$fail_restore_after" \
    bash "$ROOT/ports/appmanager/src/launcher.sh" --validate-pending
}

install_trimui_case() {
  local name=$1 mode=$2 root target frontend scripts
  root="$TMP/$name"; target="$root/Apps/PortMaster/PortMaster"
  frontend="$root/Apps/PortMaster"; scripts="$root/Roms/PORTS"
  mkdir -p "$target/libs" "$frontend" "$scripts" "$root/state" "$root/trimui-root"
  printf 'runtime-sentinel\n' > "$target/libs/keep.squashfs"
  if [ "$mode" = update ]; then
    printf 'old-control\n' > "$target/control.txt"
    printf 'old-device\n' > "$target/device_info.txt"
    printf 'old-funcs\n' > "$target/funcs.txt"
    printf "PORTMASTER_VERSION = '2026.06'\n" > "$target/pugwash"
    printf 'old-core\n' > "$target/old.txt"
    printf 'old-launcher\n' > "$frontend/launch.sh"
    printf 'old-config\n' > "$frontend/config.json"
    printf 'old-icon\n' > "$frontend/icon.png"
  fi
  write_plan trimui "$target" "$scripts" "$frontend" "$root/install-plan.tsv"
  "$INSTALLER" --archive "$TMP/PortMaster.zip" --plan "$root/install-plan.tsv" \
    --state-dir "$root/state" >/dev/null
}

validate_trimui_case() {
  local name=$1 root target
  root="$TMP/$name"; target="$root/Apps/PortMaster/PortMaster"
  PAM_SOURCE_DIR="$root/Roms/PORTS" PAM_APP_ROOT_OVERRIDE="$TMP/app" \
    PAM_STATE_DIR_OVERRIDE="$root/state" PAM_PORTMASTER_DIR_OVERRIDE="$target" \
    PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$root/trimui-root" \
    PAM_DIRECTORY_OVERRIDE="${root#/}/Data" \
    bash "$ROOT/ports/appmanager/src/launcher.sh" --validate-pending
}

install_official_case() {
  local name=$1 profile=$2 root target frontend scripts
  root="$TMP/$name"; target="$root/PortMaster"; scripts="$root/scripts"
  if [ "$profile" = muos ]; then frontend="$root/control-hack"; else frontend="$scripts"; fi
  mkdir -p "$target/libs" "$frontend" "$scripts" "$root/state"
  printf 'runtime-sentinel\n' > "$target/libs/keep.squashfs"
  write_plan "$profile" "$target" "$scripts" "$frontend" "$root/install-plan.tsv"
  "$INSTALLER" --archive "$TMP/PortMaster.zip" --plan "$root/install-plan.tsv" \
    --state-dir "$root/state" >/dev/null
}

validate_official_case() {
  local name=$1 profile=$2 root target frontend
  root="$TMP/$name"; target="$root/PortMaster"
  if [ "$profile" = muos ]; then frontend="$root/control-hack"; else frontend="$root/scripts"; fi
  if [ "$profile" = muos ]; then
    PAM_MUOS_ROOT="$root/muos-marker" PAM_KNULLI_MARKER="$TMP/no-knulli" PAM_BATOCERA_VERSION_FILE="$TMP/no-batocera" \
      PAM_SOURCE_DIR="$root/scripts" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$root/state" \
      PAM_PORTMASTER_DIR_OVERRIDE="$target" PAM_FRONTEND_DIR_OVERRIDE="$frontend" \
      PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" \
      bash "$ROOT/ports/appmanager/src/launcher.sh" --validate-pending
  else
    PAM_MUOS_ROOT="$TMP/no-muos" PAM_KNULLI_MARKER="$TMP/no-knulli" PAM_BATOCERA_VERSION_FILE="$root/batocera-version" \
      PAM_SOURCE_DIR="$root/scripts" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$root/state" \
      PAM_PORTMASTER_DIR_OVERRIDE="$target" PAM_FRONTEND_DIR_OVERRIDE="$frontend" \
      PAM_LOONG_VERSION_FILE="$TMP/no-loong" PAM_TRIMUI_ROOT="$TMP/no-trim" \
      bash "$ROOT/ports/appmanager/src/launcher.sh" --validate-pending
  fi
}

install_case success install
validate_case success
grep -Fq $'1\tvalid\t' "$TMP/success/state/validation-result.tsv"
[ ! -e "$TMP/success/state/pending-install.tsv" ]
[ ! -e "$TMP/success/PortMaster/.appmanager-rollback" ]
grep -Fxq new-core "$TMP/success/PortMaster/core.txt"
grep -Fxq runtime-sentinel "$TMP/success/PortMaster/libs/keep.squashfs"

# TrimUI uses the official Apps/PortMaster frontend contract instead of a
# generic launcher under Roms/PORTS. All four locations validate together.
install_trimui_case trimui-success install
validate_trimui_case trimui-success
grep -Fq $'1\tvalid\t' "$TMP/trimui-success/state/validation-result.tsv"
[ -x "$TMP/trimui-success/Apps/PortMaster/launch.sh" ]
[ -f "$TMP/trimui-success/Apps/PortMaster/config.json" ]
[ -f "$TMP/trimui-success/Apps/PortMaster/icon.png" ]
[ ! -e "$TMP/trimui-success/Roms/PORTS/PortMaster.sh" ]

mkdir -p "$TMP/muos-success/muos-marker"
install_official_case muos-success muos
validate_official_case muos-success muos
grep -Fq $'1\tvalid\t' "$TMP/muos-success/state/validation-result.tsv"
[ -x "$TMP/muos-success/PortMaster/PortMaster.sh" ]
[ -f "$TMP/muos-success/control-hack/control.txt" ]

mkdir -p "$TMP/batocera-success"
printf 'batocera\n' > "$TMP/batocera-success/batocera-version"
install_official_case batocera-success batocera
validate_official_case batocera-success batocera
grep -Fq $'1\tvalid\t' "$TMP/batocera-success/state/validation-result.tsv"
[ ! -e "$TMP/batocera-success/PortMaster/PortMaster.sh" ]
[ -x "$TMP/batocera-success/scripts/PortMaster.sh" ]

install_trimui_case trimui-rollback update
rm -f "$TMP/trimui-rollback/Apps/PortMaster/PortMaster/funcs.txt"
validate_trimui_case trimui-rollback || true
grep -Fq $'1\trestored\t' "$TMP/trimui-rollback/state/validation-result.tsv"
grep -Fxq old-core "$TMP/trimui-rollback/Apps/PortMaster/PortMaster/old.txt"
grep -Fxq old-launcher "$TMP/trimui-rollback/Apps/PortMaster/launch.sh"
grep -Fxq old-config "$TMP/trimui-rollback/Apps/PortMaster/config.json"
grep -Fxq old-icon "$TMP/trimui-rollback/Apps/PortMaster/icon.png"
[ ! -e "$TMP/trimui-rollback/Roms/PORTS/PortMaster.sh" ]

install_case rollback update
rm -f "$TMP/rollback/PortMaster/funcs.txt"
validate_case rollback || true
grep -Fq $'1\trestored\t' "$TMP/rollback/state/validation-result.tsv"
grep -Fxq old-core "$TMP/rollback/PortMaster/old.txt"
grep -Fxq old-launcher "$TMP/rollback/scripts/PortMaster.sh"
grep -Fxq runtime-sentinel "$TMP/rollback/PortMaster/libs/keep.squashfs"
[ ! -e "$TMP/rollback/state/pending-install.tsv" ]

# Devices updating from the previously released v2 transaction format must
# still roll back safely after this launcher upgrade.
install_case legacy-v2 update
sed -e 's/^version\t3$/version\t2/' -e '/^frontend_/d' \
  "$TMP/legacy-v2/state/pending-install.tsv" > "$TMP/legacy-v2/state/pending-v2.tmp"
mv "$TMP/legacy-v2/state/pending-v2.tmp" "$TMP/legacy-v2/state/pending-install.tsv"
mv "$TMP/legacy-v2/PortMaster/.appmanager-rollback/frontend/PortMaster.sh" \
  "$TMP/legacy-v2/PortMaster/.appmanager-rollback/PortMaster.sh"
rm -f "$TMP/legacy-v2/state/pending-frontend-manifest.tsv"
rm -f "$TMP/legacy-v2/PortMaster/funcs.txt"
validate_case legacy-v2 || true
grep -Fq $'1\trestored\t' "$TMP/legacy-v2/state/validation-result.tsv"
grep -Fxq old-core "$TMP/legacy-v2/PortMaster/old.txt"
grep -Fxq old-launcher "$TMP/legacy-v2/scripts/PortMaster.sh"

install_case first-failure install
rm -f "$TMP/first-failure/PortMaster/funcs.txt"
validate_case first-failure || true
grep -Fq $'1\tno-usable\t' "$TMP/first-failure/state/validation-result.tsv"
[ ! -e "$TMP/first-failure/PortMaster/control.txt" ]
grep -Fxq runtime-sentinel "$TMP/first-failure/PortMaster/libs/keep.squashfs"
[ ! -e "$TMP/first-failure/state/pending-install.tsv" ]

install_case interrupted update
validate_case interrupted 1 || true
grep -Fq $'1\tinterrupted\t' "$TMP/interrupted/state/validation-result.tsv"
[ -s "$TMP/interrupted/state/pending-install.tsv" ]
[ -d "$TMP/interrupted/PortMaster/.appmanager-rollback" ]
grep -Fxq new-core "$TMP/interrupted/PortMaster/core.txt"

# The frontend launcher is part of the pending contract. Losing it must restore
# the previous core instead of deleting the only known-good launcher backup.
install_case launcher-missing update
rm -f "$TMP/launcher-missing/scripts/PortMaster.sh"
validate_case launcher-missing || true
grep -Fq $'1\trestored\t' "$TMP/launcher-missing/state/validation-result.tsv"
grep -Fxq old-core "$TMP/launcher-missing/PortMaster/old.txt"
grep -Fxq old-launcher "$TMP/launcher-missing/scripts/PortMaster.sh"

# A record-boundary truncation cannot turn a full manifest into a valid subset.
install_case manifest-truncated update
head -n 1 "$TMP/manifest-truncated/state/pending-manifest.tsv" > "$TMP/manifest-truncated/state/manifest.tmp"
mv "$TMP/manifest-truncated/state/manifest.tmp" "$TMP/manifest-truncated/state/pending-manifest.tsv"
rm -f "$TMP/manifest-truncated/PortMaster/pylibs.zip"
validate_case manifest-truncated || true
grep -Fq $'1\trestored\t' "$TMP/manifest-truncated/state/validation-result.tsv"
grep -Fxq old-core "$TMP/manifest-truncated/PortMaster/old.txt"

# Damaged metadata is never allowed to downgrade an update into destructive
# first-install cleanup; actual rollback content is the conservative evidence.
install_case mode-missing update
sed '/^mode\t/d' "$TMP/mode-missing/state/pending-install.tsv" > "$TMP/mode-missing/state/pending.tmp"
mv "$TMP/mode-missing/state/pending.tmp" "$TMP/mode-missing/state/pending-install.tsv"
rm -f "$TMP/mode-missing/PortMaster/funcs.txt"
validate_case mode-missing || true
grep -Fq $'1\trestored\t' "$TMP/mode-missing/state/validation-result.tsv"
grep -Fxq old-core "$TMP/mode-missing/PortMaster/old.txt"
grep -Fxq old-launcher "$TMP/mode-missing/scripts/PortMaster.sh"
grep -Fxq runtime-sentinel "$TMP/mode-missing/PortMaster/libs/keep.squashfs"

# A failed first installation is fully removed even when its manifest is lost.
install_case first-no-manifest install
rm -f "$TMP/first-no-manifest/state/pending-manifest.tsv"
validate_case first-no-manifest || true
grep -Fq $'1\tno-usable\t' "$TMP/first-no-manifest/state/validation-result.tsv"
[ ! -e "$TMP/first-no-manifest/PortMaster/control.txt" ]
[ ! -e "$TMP/first-no-manifest/scripts/PortMaster.sh" ]
grep -Fxq runtime-sentinel "$TMP/first-no-manifest/PortMaster/libs/keep.squashfs"

# A power loss after backup but before installation leaves only a transaction;
# next-start validation must restore it automatically and preserve Runtime data.
crash_root="$TMP/crash-recovery"
mkdir -p "$crash_root/PortMaster/libs" "$crash_root/scripts" "$crash_root/state"
printf 'old-control\n' > "$crash_root/PortMaster/control.txt"
printf 'old-device\n' > "$crash_root/PortMaster/device_info.txt"
printf 'old-funcs\n' > "$crash_root/PortMaster/funcs.txt"
printf "PORTMASTER_VERSION = '2026.06'\n" > "$crash_root/PortMaster/pugwash"
printf '#!/bin/sh\nexit 0\n' > "$crash_root/PortMaster/PortMaster.sh"
printf 'old-core\n' > "$crash_root/PortMaster/old.txt"
printf 'runtime-sentinel\n' > "$crash_root/PortMaster/libs/keep.squashfs"
printf 'old-launcher\n' > "$crash_root/scripts/PortMaster.sh"
write_plan miniloong "$crash_root/PortMaster" "$crash_root/scripts" "$crash_root/scripts" "$crash_root/install-plan.tsv"
if PAM_TEST_CRASH_AFTER_BACKUP=1 "$INSTALLER" --archive "$TMP/PortMaster.zip" \
  --plan "$crash_root/install-plan.tsv" --state-dir "$crash_root/state" >/dev/null 2>&1; then
  echo "simulated crash unexpectedly succeeded" >&2
  exit 1
fi
[ -s "$crash_root/state/install-transaction.tsv" ]
validate_case crash-recovery || true
grep -Fq $'1\trestored\t' "$crash_root/state/validation-result.tsv"
grep -Fxq old-core "$crash_root/PortMaster/old.txt"
grep -Fxq old-launcher "$crash_root/scripts/PortMaster.sh"
grep -Fxq runtime-sentinel "$crash_root/PortMaster/libs/keep.squashfs"
[ ! -e "$crash_root/state/install-transaction.tsv" ]

# Rollback itself is restartable. If restoration stops after one old entry,
# retrying must keep that restored entry and continue with the remaining backup.
install_case restore-retry update
rm -f "$TMP/restore-retry/PortMaster/funcs.txt"
validate_case restore-retry 0 1 || true
grep -Fq $'1\tinterrupted\t' "$TMP/restore-retry/state/validation-result.tsv"
[ -s "$TMP/restore-retry/state/pending-install.tsv" ]
[ -f "$TMP/restore-retry/PortMaster/.appmanager-rollback/restoring" ]
validate_case restore-retry || true
grep -Fq $'1\trestored\t' "$TMP/restore-retry/state/validation-result.tsv"
grep -Fxq old-core "$TMP/restore-retry/PortMaster/old.txt"
grep -Fxq old-launcher "$TMP/restore-retry/scripts/PortMaster.sh"
grep -Fxq runtime-sentinel "$TMP/restore-retry/PortMaster/libs/keep.squashfs"

# Corrupt rollback metadata blocks destructive cleanup and keeps both the new
# core and old backup available for explicit recovery.
install_case rollback-metadata update
printf 'tampered\n' >> "$TMP/rollback-metadata/PortMaster/.appmanager-rollback/expected-tops.tsv"
rm -f "$TMP/rollback-metadata/PortMaster/funcs.txt"
validate_case rollback-metadata || true
grep -Fq $'1\tinterrupted\t' "$TMP/rollback-metadata/state/validation-result.tsv"
[ -s "$TMP/rollback-metadata/state/pending-install.tsv" ]
grep -Fxq new-core "$TMP/rollback-metadata/PortMaster/core.txt"
grep -Fxq old-core "$TMP/rollback-metadata/PortMaster/.appmanager-rollback/core/old.txt"
grep -Fxq runtime-sentinel "$TMP/rollback-metadata/PortMaster/libs/keep.squashfs"

# A second validator observes the live lock and performs no filesystem change.
install_case validation-locked update
mkdir "$TMP/validation-locked/state/validation.lock"
printf '%s\n' "$$" > "$TMP/validation-locked/state/validation.lock/pid"
validate_case validation-locked || true
grep -Fq $'1\tchecking\tAnother validation process is still running' \
  "$TMP/validation-locked/state/validation-result.tsv"
[ -s "$TMP/validation-locked/state/pending-install.tsv" ]
grep -Fxq new-core "$TMP/validation-locked/PortMaster/core.txt"
rm -rf "$TMP/validation-locked/state/validation.lock"
validate_case validation-locked
grep -Fq $'1\tvalid\t' "$TMP/validation-locked/state/validation-result.tsv"

echo "appmanager pending validation tests: PASS"
