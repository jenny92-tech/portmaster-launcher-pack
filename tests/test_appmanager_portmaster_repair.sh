#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUI="$(cd "$ROOT/../PortMaster-GUI" && pwd)"
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

"$ROOT/_kit/dist_port.sh" appmanager >/dev/null
mkdir -p "$TMP/release" "$TMP/archive/PortMaster/pylibs-src" "$TMP/app"
cp -R "$ROOT/ports/appmanager/dist/PortAppManager/." "$TMP/app/"
rm -f "$TMP/app/bin/busybox-portable"

printf 'controlfolder=/unused\n' > "$TMP/archive/PortMaster/control.txt"
printf 'device\n' > "$TMP/archive/PortMaster/device_info.txt"
printf 'functions\n' > "$TMP/archive/PortMaster/funcs.txt"
printf "PORTMASTER_VERSION = '2026.07'\n" > "$TMP/archive/PortMaster/pugwash"
printf 'stable\n' > "$TMP/archive/PortMaster/pylibs-src/module.py"
(cd "$TMP/archive/PortMaster/pylibs-src" && zip -q ../pylibs.zip module.py)
rm -rf "$TMP/archive/PortMaster/pylibs-src"
printf '#!/bin/sh\nexit 0\n' > "$TMP/archive/PortMaster/PortMaster.sh"
chmod +x "$TMP/archive/PortMaster/PortMaster.sh"
(cd "$TMP/archive" && zip -qr "$TMP/release/PortMaster.zip" PortMaster)
cp "$GUI/tools/portappmanager-installer.sh" "$TMP/release/portappmanager-installer.sh"
archive_md5=$(md5 -q "$TMP/release/PortMaster.zip" 2>/dev/null || md5sum "$TMP/release/PortMaster.zip" | awk '{print $1}')
printf '%s  PortMaster.zip\n' "$archive_md5" > "$TMP/release/PortMaster.zip.md5"
cat > "$TMP/release/version.json" <<'JSON'
{
  "stable": {
    "version": "2026.07",
    "url": "https://github.com/jenny92-tech/PortMaster-GUI/releases/download/2026.07/PortMaster.zip"
  }
}
JSON
(cd "$TMP/release" && shasum -a 256 version.json PortMaster.zip > SHA256SUMS)

cat > "$TMP/app/bin/curl-portable" <<'CURL'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then echo 'curl test'; exit 0; fi
printf '%s\n' "$*" >> "$PAM_TEST_CURL_LOG"
out=""; url=""; resume=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -C) resume=1; shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
asset=${url##*/}
[ -f "$PAM_TEST_RELEASE/$asset" ] || exit 22
source_file="$PAM_TEST_RELEASE/$asset"
if [ -n "$out" ]; then
  if [ "$asset" = "PortMaster.zip" ] && [ "${PAM_TEST_PARTIAL:-0}" = "1" ]; then
    if [ ! -s "$out" ]; then
      size=$(wc -c < "$source_file" | tr -d '[:space:]')
      head -c "$((size / 2))" "$source_file" > "$out"
    fi
    exit 28
  elif [ "$asset" = "PortMaster.zip" ] && [ "$resume" = 1 ] && [ -s "$out" ]; then
    current=$(wc -c < "$out" | tr -d '[:space:]')
    printf 'resume-from=%s\n' "$current" >> "$PAM_TEST_CURL_LOG"
    tail -c "+$((current + 1))" "$source_file" >> "$out"
  elif [ "$asset" = "PortMaster.zip" ] && [ "${PAM_TEST_CORRUPT:-0}" = "1" ]; then
    printf 'corrupt archive\n' > "$out"
  elif [ "$asset" = "PortMaster.zip" ] && [ "${PAM_TEST_SLOW:-0}" = "1" ]; then
    size=$(wc -c < "$source_file" | tr -d '[:space:]')
    half=$((size / 2))
    : > "$out"
    sleep 1
    head -c "$half" "$source_file" >> "$out"
    sleep 2
    tail -c "+$((half + 1))" "$source_file" >> "$out"
  else
    cp "$source_file" "$out"
  fi
else
  head -c 16 "$source_file"
fi
if [ "$asset" = "${PAM_TEST_CANCEL_ON_ASSET:-never}" ]; then : > "$PAM_TEST_CANCEL_FILE"; fi
CURL
cat > "$TMP/app/bin/unzip-portable" <<'UNZIP'
#!/bin/sh
exec unzip "$@"
UNZIP
cat > "$TMP/app/bin/sha256sum-portable" <<'SHA'
#!/bin/sh
exec shasum -a 256 "$@"
SHA
chmod +x "$TMP/app/bin/curl-portable" "$TMP/app/bin/unzip-portable" "$TMP/app/bin/sha256sum-portable"

run_repair() {
  local name=$1 corrupt=${2:-0} cancel_asset=${3:-never} existing=${4:-0} cached=${5:-0} slow=${6:-0}
  local channel=${7:-official} partial=${8:-0} release_base loong_file
  local state="$TMP/$name/state" target="$TMP/$name/PortMaster" scripts="$TMP/$name/scripts"
  local observer_pid=0 rc=0
  mkdir -p "$state" "$scripts" "$target/libs"
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
  printf '# plan\nINSTALL_PORTMASTER\tstable\n' > "$state/plan.txt"
  if [ "$channel" = custom ]; then
    mkdir -p "$TMP/loong"; printf '1.0\n' > "$TMP/loong/loong_version"
    loong_file="$TMP/loong/loong_version"
  else
    loong_file="$TMP/no-loong"
  fi
  release_base="https://github.com/jenny92-tech/PortMaster-GUI/releases/latest/download"
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
  PAM_SOURCE_DIR="$TMP" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$state" \
    PAM_PORTMASTER_DIR_OVERRIDE="$target" PAM_DIRECTORY_OVERRIDE="${TMP#/}/$name/data" \
    PAM_DEVICE_CLASS_OVERRIDE=tested PAM_TARGET_CONFIRMED_OVERRIDE=1 \
    PAM_PARAM_DEVICE_OVERRIDE=miniloong \
    PAM_LOONG_VERSION_FILE="$loong_file" PAM_RELEASE_BASE="$release_base" \
    PAM_RUNTIME_CUSTOM_PROXIES='custom|test|https://proxy.invalid' PAM_RUNTIME_PROXIES='' \
    PAM_TEST_RELEASE="$TMP/release" PAM_TEST_CURL_LOG="$TMP/$name/curl.log" PAM_TEST_CORRUPT="$corrupt" PAM_TEST_SLOW="$slow" \
    PAM_TEST_PARTIAL="$partial" \
    PAM_TEST_CANCEL_ON_ASSET="$cancel_asset" PAM_TEST_CANCEL_FILE="$state/cancel.request" \
    bash "$ROOT/ports/appmanager/src/launcher.sh" --apply-plan || rc=$?
  if [ "$observer_pid" != 0 ]; then wait "$observer_pid" || true; fi
  return "$rc"
}

run_repair success
[ -f "$TMP/success/PortMaster/control.txt" ]
[ -f "$TMP/success/PortMaster/libs/keep.squashfs" ]
[ -s "$TMP/success/state/pending-install.tsv" ]
[ -s "$TMP/success/state/pending-manifest.tsv" ]
grep -Fq $'OK\tportmaster\tpending-validation' "$TMP/success/state/result.txt"
grep -Fq -- '-C -' "$TMP/success/curl.log"
grep -Fq $'complete\tPortMaster' "$TMP/success/state/progress.tsv"
grep -Fq 'jenny92-tech/PortMaster-GUI/releases/latest/download/version.json' "$TMP/success/curl.log"
grep -Fq 'jenny92-tech/PortMaster-GUI/raw/refs/heads/miniloong-support/tools/portappmanager-installer.sh' "$TMP/success/curl.log"
! grep -Fq '/Install.sh' "$TMP/success/curl.log"
grep -Fq 'PortsMaster/PortMaster-GUI/releases/download/2026.07/PortMaster.zip.md5' "$TMP/success/curl.log"
grep -Fq 'PortsMaster/PortMaster-GUI/releases/download/2026.07/PortMaster.zip' "$TMP/success/curl.log"

run_repair miniloong-custom 0 never 0 0 0 custom
grep -Fq 'jenny92-tech/PortMaster-GUI' "$TMP/miniloong-custom/curl.log"
! grep -Fq 'PortsMaster/PortMaster-GUI/releases/download' "$TMP/miniloong-custom/curl.log"
grep -Fq $'device\tminiloong' "$TMP/miniloong-custom/state/pending-install.tsv"

run_repair cached 0 never 0 1
! grep -Fq '/PortMaster.zip' "$TMP/cached/curl.log"

# A failed operation keeps its version-scoped partial archive. The next APP
# launch resumes that exact stable release instead of starting over.
run_repair resume 0 never 0 0 0 official 1 || true
grep -Fq $'FAIL\tportmaster\tnetwork' "$TMP/resume/state/result.txt"
[ -s "$TMP/resume/state/portmaster-download/2026.07/PortMaster.zip" ]
run_repair resume
grep -Fq 'resume-from=' "$TMP/resume/curl.log"
grep -Fq $'OK\tportmaster\tpending-validation' "$TMP/resume/state/result.txt"

run_repair speed 0 never 0 0 1
[ -e "$TMP/speed/speed-observed" ]

run_repair update 0 never 1
grep -Fq $'mode\tupdate' "$TMP/update/state/pending-install.tsv"
[ -f "$TMP/update/PortMaster/.appmanager-rollback/core/old.txt" ]
grep -Fq "PORTMASTER_VERSION = '2026.07'" "$TMP/update/PortMaster/pugwash"
grep -Fxq 'runtime sentinel' "$TMP/update/PortMaster/libs/keep.squashfs"

run_repair checksum 1 || true
grep -Fq $'FAIL\tportmaster\tchecksum' "$TMP/checksum/state/result.txt"
[ ! -f "$TMP/checksum/PortMaster/control.txt" ]
[ -f "$TMP/checksum/PortMaster/libs/keep.squashfs" ]

run_repair cancelled 0 PortMaster.zip || true
grep -Fq $'FAIL\tportmaster\tcancelled' "$TMP/cancelled/state/result.txt"
grep -Fq $'cancelled\tPortMaster' "$TMP/cancelled/state/progress.tsv"
[ ! -f "$TMP/cancelled/PortMaster/control.txt" ]
[ -f "$TMP/cancelled/PortMaster/libs/keep.squashfs" ]

echo "appmanager PortMaster repair tests: PASS"
