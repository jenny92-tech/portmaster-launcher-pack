#!/usr/bin/env bash
# INPUT:  Docker、portkit_launcher_revision.py、Cargo 与 portkit-launcher 源码
# OUTPUT: runtime/portkit-launcher.aarch64 与 portkit-launcher-revision.txt
# POS:    构建并校验普通游戏启动器使用的 ARM64 静态辅助程序
# Build the small static aarch64 PortKit helper used by game launchers.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${PORTKIT_LAUNCHER_BUILD_IMAGE:-rust:1.88-alpine}"
OUT="$ROOT/_kit/runtime/portkit-launcher.aarch64"
REVISION_FILE="$ROOT/_kit/portkit-launcher-revision.txt"
STAGING="$ROOT/.tmp/portkit-launcher-build"

PYTHON="${PYTHON:-python3}"
if ! "$PYTHON" -c 'import tomllib' >/dev/null 2>&1; then
  for candidate in python3.13 python3.12 python3.11; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
      PYTHON="$candidate"
      break
    fi
  done
fi
"$PYTHON" -c 'import tomllib' >/dev/null 2>&1 || {
  echo "Python 3.11 or newer is required to build the PortKit launcher helper." >&2
  exit 69
}

REVISION="$("$PYTHON" "$ROOT/_kit/portkit_launcher_revision.py" "$ROOT")"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required to build the portable PortKit launcher helper." >&2
  exit 69
}

mkdir -p "$STAGING" "$(dirname "$OUT")"
docker run --rm --platform linux/arm64 \
  -e PORTKIT_LAUNCHER_SOURCE_REVISION="$REVISION" \
  -v "$ROOT:/work" \
  -w /work \
  "$IMAGE" \
  sh -c '
    set -euo pipefail
    apk add --no-cache build-base perl >/dev/null
    CARGO_TARGET_DIR=/tmp/portkit-launcher-target \
      cargo build --locked --release -p portkit-launcher --bin portkit-launcher
    install -m 0755 /tmp/portkit-launcher-target/release/portkit-launcher \
      /work/.tmp/portkit-launcher-build/portkit-launcher.aarch64
  '

install -m 0755 "$STAGING/portkit-launcher.aarch64" "$OUT"
printf '%s\n' "$REVISION" > "$REVISION_FILE"

description=$(file "$OUT")
case "$description" in
  *ELF*ARM\ aarch64*static*) ;;
  *) echo "PortKit launcher helper is not a static aarch64 ELF: $description" >&2; exit 65 ;;
esac
grep -aFq "$REVISION" "$OUT" || {
  echo "PortKit launcher helper does not contain its source revision" >&2
  exit 65
}
echo "$description"
