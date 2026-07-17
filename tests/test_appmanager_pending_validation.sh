#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/../PortMaster-GUI/tools/appmanager-install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/source/PortMaster/pylibs-src" "$TMP/app/bin" "$TMP/app/love_ui"
mkdir -p "$TMP/loong"
printf '1.0\n' > "$TMP/loong/loong_version"
printf 'new-control\n' > "$TMP/source/PortMaster/control.txt"
printf 'new-device\n' > "$TMP/source/PortMaster/device_info.txt"
printf 'new-funcs\n' > "$TMP/source/PortMaster/funcs.txt"
printf "PORTMASTER_VERSION = '2026.07'\n" > "$TMP/source/PortMaster/pugwash"
printf '#!/bin/sh\nexit 0\n' > "$TMP/source/PortMaster/PortMaster.sh"
printf 'new-core\n' > "$TMP/source/PortMaster/core.txt"
printf 'module\n' > "$TMP/source/PortMaster/pylibs-src/module.py"
(cd "$TMP/source/PortMaster/pylibs-src" && zip -q ../pylibs.zip module.py)
rm -rf "$TMP/source/PortMaster/pylibs-src"
(cd "$TMP/source" && zip -qr "$TMP/PortMaster.zip" PortMaster)
cat > "$TMP/app/bin/sha256sum-portable" <<'SHA'
#!/bin/sh
exec shasum -a 256 "$@"
SHA
chmod +x "$TMP/app/bin/sha256sum-portable"
printf 'return {}\n' > "$TMP/app/love_ui/runtime_catalog.tsv"

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
  "$INSTALLER" --archive "$TMP/PortMaster.zip" --target "$target" --scripts "$root/scripts" \
    --state-dir "$root/state" --device miniloong >/dev/null
}

validate_case() {
  local name=$1 interrupted=${2:-0} root
  root="$TMP/$name"
  PAM_SOURCE_DIR="$root/scripts" PAM_APP_ROOT_OVERRIDE="$TMP/app" \
    PAM_STATE_DIR_OVERRIDE="$root/state" PAM_PORTMASTER_DIR_OVERRIDE="$root/PortMaster" \
    PAM_LOONG_VERSION_FILE="$TMP/loong/loong_version" \
    PAM_DIRECTORY_OVERRIDE="${root#/}/data" PAM_TEST_INTERRUPT_VALIDATION="$interrupted" \
    bash "$ROOT/ports/appmanager/src/launcher.sh" --validate-pending
}

install_case success install
validate_case success
grep -Fq $'1\tvalid\t' "$TMP/success/state/validation-result.tsv"
[ ! -e "$TMP/success/state/pending-install.tsv" ]
[ ! -e "$TMP/success/state/rollback" ]
grep -Fxq new-core "$TMP/success/PortMaster/core.txt"
grep -Fxq runtime-sentinel "$TMP/success/PortMaster/libs/keep.squashfs"

install_case rollback update
rm -f "$TMP/rollback/PortMaster/funcs.txt"
validate_case rollback || true
grep -Fq $'1\trestored\t' "$TMP/rollback/state/validation-result.tsv"
grep -Fxq old-core "$TMP/rollback/PortMaster/old.txt"
grep -Fxq old-launcher "$TMP/rollback/scripts/PortMaster.sh"
grep -Fxq runtime-sentinel "$TMP/rollback/PortMaster/libs/keep.squashfs"
[ ! -e "$TMP/rollback/state/pending-install.tsv" ]

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
[ -d "$TMP/interrupted/state/rollback" ]
grep -Fxq new-core "$TMP/interrupted/PortMaster/core.txt"

echo "appmanager pending validation tests: PASS"
