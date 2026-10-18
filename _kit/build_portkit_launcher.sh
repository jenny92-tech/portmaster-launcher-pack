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
cache_args=()
registry="${CARGO_HOME:-$HOME/.cargo}/registry"
[ ! -d "$registry" ] || cache_args=(-v "$registry:/usr/local/cargo/registry")
docker run --rm --platform linux/arm64 --cpus 2 --memory 4g \
  -e PORTKIT_LAUNCHER_SOURCE_REVISION="$REVISION" \
  "${cache_args[@]}" \
  -v "$ROOT:/work" \
  -w /work \
  "$IMAGE" \
  sh -ec '
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache build-base perl >/dev/null
    fi
    build_target=$(rustc -vV | sed -n "s/^host: //p")
    case "$build_target" in
      aarch64-unknown-linux-musl) ;;
      *) echo "portable launcher helper requires an aarch64 musl toolchain" >&2; exit 65 ;;
    esac
    export CARGO_TARGET_DIR=/work/.tmp/portkit-launcher-build/target
    cargo build --locked --release --target "$build_target" -p portkit-launcher --bin portkit-launcher
    install -m 0755 "$CARGO_TARGET_DIR/$build_target/release/portkit-launcher" \
      /work/.tmp/portkit-launcher-build/portkit-launcher.aarch64
    /work/.tmp/portkit-launcher-build/portkit-launcher.aarch64 version
  '

description=$(file "$STAGING/portkit-launcher.aarch64")
case "$description" in
  *ELF*ARM\ aarch64*static*) ;;
  *) echo "PortKit launcher helper is not a static aarch64 ELF: $description" >&2; exit 65 ;;
esac
grep -aFq "$REVISION" "$STAGING/portkit-launcher.aarch64" || {
  echo "PortKit launcher helper does not contain its source revision" >&2
  exit 65
}
install -m 0755 "$STAGING/portkit-launcher.aarch64" "$OUT"
printf '%s\n' "$REVISION" > "$REVISION_FILE"
echo "$description"
