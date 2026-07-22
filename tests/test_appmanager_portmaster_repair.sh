#!/usr/bin/env bash
set -euo pipefail
export PAM_TOOL_MODE=system # Host fixtures run on macOS, not the packaged aarch64 runtime.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  local rc=$?
  if [ "$rc" != 0 ]; then
    find "$TMP" -name log.txt -o -name result.txt -o -name progress.tsv | while read -r file; do
      echo "--- $file" >&2; sed -n '1,240p' "$file" >&2
    done
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

bash "$ROOT/_kit/dist_port.sh" appmanager >/dev/null
cargo build --quiet --manifest-path "$ROOT/Cargo.toml" -p appmanager-cli -p portkit-cli
grep -Fq 'refresh-runtime-metadata' "$ROOT/ports/appmanager/src/launcher.sh"
! grep -Eq '^(runtime_metadata_parse|pam_cache_mtime)\(\)' "$ROOT/ports/appmanager/src/launcher.sh"
grep -Fq 'fetch-stable-release' "$ROOT/ports/appmanager/src/launcher.sh"
! grep -Eq '^(pam_stable_metadata_parse|pm_valid_stable_archive_url|pm_valid_md5)\(\)' \
  "$ROOT/ports/appmanager/src/launcher.sh"
mkdir -p "$TMP/release" "$TMP/archive/PortMaster/pylibs-src" "$TMP/archive/PortMaster/miniloong" "$TMP/app"
cp -R "$ROOT/ports/appmanager/dist/jenny92-appmanager/." "$TMP/app/"
rm -f "$TMP/app/bin/busybox-portable"

printf 'controlfolder=/unused\n' > "$TMP/archive/PortMaster/control.txt"
printf 'device\n' > "$TMP/archive/PortMaster/device_info.txt"
printf 'functions\n' > "$TMP/archive/PortMaster/funcs.txt"
printf "PORTMASTER_VERSION = '2026.07'\n" > "$TMP/archive/PortMaster/pugwash"
printf 'stable\n' > "$TMP/archive/PortMaster/pylibs-src/module.py"
(cd "$TMP/archive/PortMaster/pylibs-src" && zip -q ../pylibs.zip module.py)
rm -rf "$TMP/archive/PortMaster/pylibs-src"
printf '#!/bin/sh\nexit 0\n' > "$TMP/archive/PortMaster/PortMaster.sh"
printf '#!/bin/sh\nexec "$(dirname "$0")/PortMaster/PortMaster.sh"\n' > "$TMP/archive/PortMaster/miniloong/PortMaster.txt"
chmod +x "$TMP/archive/PortMaster/PortMaster.sh"
(cd "$TMP/archive" && zip -qr "$TMP/release/PortMaster.zip" PortMaster)
archive_md5=$(md5 -q "$TMP/release/PortMaster.zip" 2>/dev/null || md5sum "$TMP/release/PortMaster.zip" | awk '{print $1}')
printf '%s\n' "{\"stable\":{\"md5\":\"$archive_md5\",\"url\":\"https://github.com/jenny92-tech/PortMaster-GUI/releases/download/2026.07/PortMaster.zip\",\"version\":\"2026.07\"}}" > "$TMP/release/version.json"
printf '%s\n' "{\"stable\":{\"url\":\"https://github.com/PortsMaster/PortMaster-GUI/releases/download/2026.07/PortMaster.zip\",\"md5\":\"$archive_md5\",\"version\":\"2026.07\"}}" > "$TMP/release/official-version.json"
(printf 'hsqs'; printf '%016d' 0) > "$TMP/release/python_3.11.squashfs"
python_size=$(wc -c < "$TMP/release/python_3.11.squashfs" | tr -d '[:space:]')
python_md5=$(md5 -q "$TMP/release/python_3.11.squashfs" 2>/dev/null || md5sum "$TMP/release/python_3.11.squashfs" | awk '{print $1}')
cat > "$TMP/release/ports.json" <<JSON
{
  "utils": {
    "python_3.11.aarch64.squashfs": {
      "runtime_name": "python_3.11.squashfs",
      "runtime_arch": "aarch64",
      "size": $python_size,
      "md5": "$python_md5",
      "url": "https://github.com/PortsMaster/PortMaster-New/releases/download/test/python_3.11.squashfs"
    }
  }
}
JSON

cat > "$TMP/appmanager-test" <<'CLI'
#!/bin/sh
case "${1:-}" in
  refresh-runtime-metadata)
    shift; json_cache=""; tsv_cache=""; source=""; force=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --source) source=$2; shift 2 ;;
        --json-cache) json_cache=$2; shift 2 ;;
        --tsv-cache) tsv_cache=$2; shift 2 ;;
        --force) force=1; shift ;;
        *) shift ;;
      esac
    done
    if [ "$force" != 1 ] && [ -s "$json_cache" ] && [ -s "$tsv_cache" ]; then
      printf '%s\n' '{"ok":true}'; exit 0
    fi
    printf '%s\n' "$source" >> "$PAM_TEST_FETCH_LOG"
    cp "$PAM_TEST_RELEASE/ports.json" "$json_cache"
    printf 'python_3.11\taarch64\t%s\t%s\thttps://github.com/PortsMaster/PortMaster-New/releases/download/test/python_3.11.squashfs\n' \
      "$PAM_TEST_PYTHON_SIZE" "$PAM_TEST_PYTHON_MD5" > "$tsv_cache"
    printf '%s\n' '{"ok":true}'; exit 0
    ;;
  fetch-stable-release)
    shift; out=""; source=""; archive_name=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --source) source=$2; shift 2 ;;
        --archive-name) archive_name=$2; shift 2 ;;
        --output) out=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$source" >> "$PAM_TEST_FETCH_LOG"
    case "$source" in
      *PortsMaster/PortMaster-GUI*) repo=PortsMaster/PortMaster-GUI ;;
      *) repo=jenny92-tech/PortMaster-GUI ;;
    esac
    printf '2026.07\thttps://github.com/%s/releases/download/2026.07/%s\t%s\n' \
      "$repo" "$archive_name" "$PAM_TEST_ARCHIVE_MD5" > "$out"
    printf '%s\n' '{"ok":true}'; exit 0
    ;;
esac
exec "$PAM_REAL_APPMANAGER" "$@"
CLI
cat > "$TMP/portkit-test" <<'PORTKIT'
#!/bin/sh
if [ "${1:-}" != github ] || [ "${2:-}" != fetch ]; then exec "$PAM_REAL_PORTKIT" "$@"; fi
shift 2
out=""; source=""; expected=""; progress=""; cancel=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) source=$2; shift 2 ;;
    --output) out=$2; shift 2 ;;
    --expected-md5) expected=$2; shift 2 ;;
    --progress) progress=$2; shift 2 ;;
    --cancel-file) cancel=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$source" >> "$PAM_TEST_FETCH_LOG"
asset=${source##*/}; source_file="$PAM_TEST_RELEASE/$asset"
[ -f "$source_file" ] || exit 22
if [ "$asset" = "PortMaster.zip" ] && [ "${PAM_TEST_PARTIAL:-0}" = "1" ] && [ ! -s "$out.part" ]; then
      size=$(wc -c < "$source_file" | tr -d '[:space:]')
      head -c "$((size / 2))" "$source_file" > "$out.part"
      exit 2
fi
if [ "$asset" = "${PAM_TEST_CANCEL_ON_ASSET:-never}" ]; then
  : > "$cancel"; [ -z "$progress" ] || printf '1\tcancelled\tPortMaster\t1\t1\t0\t0\t0\tCancelled\n' > "$progress"
  exit 70
fi
if [ "$asset" = PortMaster.zip ] && [ "${PAM_TEST_CORRUPT:-0}" = 1 ]; then
  printf 'corrupt archive\n' > "$out"; exit 65
fi
[ -z "$progress" ] || printf '1\tdownloading\tPortMaster\t1\t1\t1\t2\t1\t\n' > "$progress"
[ "${PAM_TEST_SLOW:-0}" != 1 ] || sleep 1
cp "$source_file" "$out"
rm -f "$out.part" "$out.part.route"
if [ -n "$expected" ]; then
  actual=$(md5 -q "$out" 2>/dev/null || md5sum "$out" | awk '{print $1}')
  [ "$actual" = "$expected" ] || { rm -f "$out"; exit 65; }
fi
printf '%s\n' '{"ok":true}'
PORTKIT
chmod +x "$TMP/appmanager-test" "$TMP/portkit-test"

run_repair() {
  local name=$1 corrupt=${2:-0} cancel_asset=${3:-never} existing=${4:-0} cached=${5:-0} slow=${6:-0}
  local channel=${7:-official} partial=${8:-0} force_python_runtime=${9:-0} cached_python=${10:-0}
  local device_root="$TMP/$name/device"
  local state="$TMP/$name/state" scripts="$device_root/mnt/sdcard/roms/ports"
  local target="$scripts/PortMaster"
  local observer_pid=0 rc=0
  mkdir -p "$state" "$scripts" "$target/libs"
  printf '#!/bin/sh\nexit 0\n' > "$scripts/APP Manager.sh"
  if [ "$cached_python" = 1 ]; then
    cp "$TMP/release/python_3.11.squashfs" "$target/libs/python_3.11.squashfs"
    printf 'python_3.11\taarch64\t%s\t%s\thttps://github.com/PortsMaster/PortMaster-New/releases/download/test/python_3.11.squashfs\n' \
      "$python_size" "$python_md5" > "$state/runtime-metadata.tsv"
  fi
  if [ "$cached" = 1 ]; then
    mkdir -p "$state/portmaster-download/2026.07"
    cp "$TMP/release/PortMaster.zip" "$state/portmaster-download/2026.07/PortMaster.zip"
  fi
  printf 'runtime sentinel\n' > "$target/libs/keep.squashfs"
  if [ "$existing" = 1 ]; then
    printf 'old-control\n' > "$target/control.txt"
    printf 'old-device\n' > "$target/device_info.txt"
    printf 'old-funcs\n' > "$target/funcs.txt"
    printf "PORTMASTER_VERSION = '2026.06'\n" > "$target/pugwash"
    printf 'old-core\n' > "$target/old.txt"
    printf 'old-launcher\n' > "$scripts/PortMaster.sh"
  fi
  if [ "$channel" = custom ]; then
    mkdir -p "$device_root/loong"; printf '1.0\n' > "$device_root/loong/loong_version"
    printf '# plan\nINSTALL_PORTMASTER\tstable\n' > "$state/plan.txt"
  else
    printf '# plan\nACK_DEVICE_RISK\tunsupported-known\nACK_DEVICE_SUPPORT\t%s\nINSTALL_PORTMASTER\tstable\n' \
      "$target" > "$state/plan.txt"
  fi
  if [ "$slow" = 1 ]; then
    (
      for _ in $(seq 1 80); do
        speed=$(awk -F '\t' '$2 == "downloading" {print $8}' "$state/progress.tsv" 2>/dev/null | tail -n 1 || true)
        case "$speed" in ""|0|*[!0-9]*) ;; *) : > "$TMP/$name/speed-observed"; exit 0 ;; esac
        sleep 0.1
      done
    ) &
    observer_pid=$!
  fi
  PAM_SOURCE_DIR="$scripts" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$state" \
    PAM_PORTMASTER_DIR_OVERRIDE="$target" PAM_DIRECTORY_OVERRIDE="$device_root/mnt/sdcard/ports/appmanager" \
    PAM_NATIVE_ROOT="$device_root" \
    PAM_NATIVE_LAUNCHER_OVERRIDE="$scripts/APP Manager.sh" \
    PAM_REAL_APPMANAGER="$ROOT/target/debug/appmanager-cli" \
    PAM_REAL_PORTKIT="$ROOT/target/debug/portkit" \
    PAM_APPMANAGER_CLI_BIN_OVERRIDE="$TMP/appmanager-test" \
    PAM_PORTKIT_BIN_OVERRIDE="$TMP/portkit-test" \
    PAM_PYTHON3_CMD_OVERRIDE="$([ "$force_python_runtime" = 1 ] && echo /missing/python3 || echo python3)" \
    PAM_RUNTIME_CUSTOM_PROXIES='custom|test|https://proxy.invalid' PAM_RUNTIME_PROXIES='' \
    PAM_TEST_RELEASE="$TMP/release" PAM_TEST_ARCHIVE_MD5="$archive_md5" \
    PAM_TEST_PYTHON_SIZE="$python_size" PAM_TEST_PYTHON_MD5="$python_md5" \
    PAM_TEST_FETCH_LOG="$TMP/$name/fetch.log" PAM_TEST_CORRUPT="$corrupt" PAM_TEST_SLOW="$slow" \
    PAM_TEST_PARTIAL="$partial" \
    PAM_TEST_CANCEL_ON_ASSET="$cancel_asset" PAM_TEST_CANCEL_FILE="$state/cancel.request" \
    bash "$ROOT/ports/appmanager/src/launcher.sh" --apply-plan || rc=$?
  if [ "$observer_pid" != 0 ]; then wait "$observer_pid" || true; fi
  return "$rc"
}

run_repair success
[ -f "$TMP/success/device/mnt/sdcard/roms/ports/PortMaster/control.txt" ]
[ -f "$TMP/success/device/mnt/sdcard/roms/ports/PortMaster/libs/keep.squashfs" ]
[ -s "$TMP/success/state/pending-install.tsv" ]
[ -s "$TMP/success/state/pending-manifest.tsv" ]
grep -Fq $'OK\tportmaster\tpending-validation' "$TMP/success/state/result.txt"
grep -Fq $'complete\tPortMaster' "$TMP/success/state/progress.tsv"
grep -Fq 'PortsMaster/PortMaster-GUI/releases/latest/download/version.json' "$TMP/success/fetch.log"
! grep -Fq 'jenny92-tech/PortMaster-GUI/releases/latest/download/version.json' "$TMP/success/fetch.log"
! grep -Fq '/SHA256SUMS' "$TMP/success/fetch.log"
! grep -Fq 'appmanager-installer.sh' "$TMP/success/fetch.log"
! grep -Fq '/Install.sh' "$TMP/success/fetch.log"
grep -Fq 'PortsMaster/PortMaster-GUI/releases/download/2026.07/PortMaster.zip' "$TMP/success/fetch.log"

run_repair miniloong-custom 0 never 0 0 0 custom
grep -Fq 'jenny92-tech/PortMaster-GUI/releases/latest/download/version.json' "$TMP/miniloong-custom/fetch.log"
! grep -Fq '/SHA256SUMS' "$TMP/miniloong-custom/fetch.log"
! grep -Fq 'PortsMaster/PortMaster-GUI/releases/download' "$TMP/miniloong-custom/fetch.log"
grep -Fq $'device\tminiloong' "$TMP/miniloong-custom/state/pending-install.tsv"

run_repair python-bootstrap-cached 0 never 0 0 0 custom 0 1 1
! grep -Fq '/ports.json' "$TMP/python-bootstrap-cached/fetch.log"
! grep -Fq '/python_3.11.squashfs' "$TMP/python-bootstrap-cached/fetch.log"
cmp "$TMP/release/python_3.11.squashfs" "$TMP/python-bootstrap-cached/device/mnt/sdcard/roms/ports/PortMaster/libs/python_3.11.squashfs"

run_repair cached 0 never 0 1
! grep -Fq '/PortMaster.zip' "$TMP/cached/fetch.log"

# A failed operation keeps its version-scoped partial archive. A later launch
# resumes only when normal probing selects the same route; otherwise it safely
# restarts instead of treating the route sidecar as persistent preference.
run_repair resume 0 never 0 0 0 official 1 || true
grep -Fq $'FAIL\tportmaster\tnetwork' "$TMP/resume/state/result.txt"
[ -s "$TMP/resume/state/portmaster-download/2026.07/PortMaster.zip.part" ]
run_repair resume
grep -Fq $'OK\tportmaster\tpending-validation' "$TMP/resume/state/result.txt"
[ ! -e "$TMP/resume/state/portmaster-download/2026.07/PortMaster.zip.part" ]
[ ! -e "$TMP/resume/state/portmaster-download/2026.07/PortMaster.zip.part.route" ]

run_repair speed 0 never 0 0 1
[ -e "$TMP/speed/speed-observed" ]

run_repair update 0 never 1
grep -Fq $'mode\tupdate' "$TMP/update/state/pending-install.tsv"
[ -f "$TMP/update/device/mnt/sdcard/roms/ports/PortMaster/.appmanager-rollback/core/old.txt" ]
grep -Fq "PORTMASTER_VERSION = '2026.07'" "$TMP/update/device/mnt/sdcard/roms/ports/PortMaster/pugwash"
grep -Fxq 'runtime sentinel' "$TMP/update/device/mnt/sdcard/roms/ports/PortMaster/libs/keep.squashfs"

run_repair checksum 1 || true
grep -Fq $'FAIL\tportmaster\tchecksum' "$TMP/checksum/state/result.txt"
[ ! -f "$TMP/checksum/device/mnt/sdcard/roms/ports/PortMaster/control.txt" ]
[ -f "$TMP/checksum/device/mnt/sdcard/roms/ports/PortMaster/libs/keep.squashfs" ]

run_repair cancelled 0 PortMaster.zip || true
grep -Fq $'FAIL\tportmaster\tcancelled' "$TMP/cancelled/state/result.txt"
grep -Fq $'cancelled\tPortMaster' "$TMP/cancelled/state/progress.tsv"
[ ! -f "$TMP/cancelled/device/mnt/sdcard/roms/ports/PortMaster/control.txt" ]
[ -f "$TMP/cancelled/device/mnt/sdcard/roms/ports/PortMaster/libs/keep.squashfs" ]

echo "appmanager PortMaster repair tests: PASS"
