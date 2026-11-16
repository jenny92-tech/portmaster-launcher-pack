#!/usr/bin/env bash
# INPUT:  Docker、portkit_launcher_revision.py、Cargo 与 portkit-launcher 源码
# OUTPUT: 默认仅生成正式 helper；debug 参数单独生成开发工具，不进入发行暂存
# POS:    构建并校验普通游戏启动器使用的 ARM64 静态辅助程序
# Build the small static aarch64 PortKit helper used by game launchers.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${PORTKIT_LAUNCHER_BUILD_IMAGE:-rust:1.88-alpine}"
case "${1:-release}" in
  release)
    BINARY=portkit-launcher
    OUT="$ROOT/_kit/runtime/$BINARY.aarch64"
    REVISION_FILE="$ROOT/_kit/portkit-launcher-revision.txt" ;;
  debug)
    BINARY=portkit-debug-launch
    OUT="$ROOT/_kit/debug/runtime/$BINARY.aarch64"
    REVISION_FILE="$OUT.source-revision" ;;
  *) echo "Usage: $0 [release|debug]" >&2; exit 64 ;;
esac
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
  -e PORTKIT_BUILD_BINARY="$BINARY" \
  "${cache_args[@]}" \
  -v "$ROOT:/work" \
  -w /work \
  "$IMAGE" \
  sh -ec '
    # The trusted Rust Alpine image already supplies cc and musl headers.
    # These helpers need no additional distribution packages.
    command -v cc >/dev/null || { echo "C linker is missing in the selected builder" >&2; exit 69; }
    build_target=$(rustc -vV | sed -n "s/^host: //p")
    case "$build_target" in
      aarch64-unknown-linux-musl) ;;
      *) echo "portable launcher helper requires an aarch64 musl toolchain" >&2; exit 65 ;;
    esac
    # The official image has cc but may omit musl-dev CRT/linker aliases.
    # Rust ships the matching musl startup objects itself. Host proc macros
    # are shared objects; use those trusted objects and the existing loader,
    # without installing packages or changing runtime/static linkage policy.
    if [ ! -f /usr/lib/crti.o ] || [ ! -e /usr/lib/libc.so ]; then
      crt_root=$(rustc --print sysroot)/lib/rustlib/$build_target/lib/self-contained
      link_dir=$(mktemp -d)
      for object in "$crt_root/"*.o; do ln -s "$object" "$link_dir/"; done
      ln -s /lib/ld-musl-aarch64.so.1 "$link_dir/libc.so"
      export LIBRARY_PATH="$link_dir${LIBRARY_PATH:+:$LIBRARY_PATH}"
    fi
    export CARGO_TARGET_DIR=/work/.tmp/portkit-launcher-build/target
    cargo build --locked --release --target "$build_target" -p portkit-launcher --bin "$PORTKIT_BUILD_BINARY"
    install -m 0755 "$CARGO_TARGET_DIR/$build_target/release/$PORTKIT_BUILD_BINARY" \
      /work/.tmp/portkit-launcher-build/$PORTKIT_BUILD_BINARY.aarch64
    /work/.tmp/portkit-launcher-build/$PORTKIT_BUILD_BINARY.aarch64 version
  '

description=$(file "$STAGING/$BINARY.aarch64")
case "$description" in
  *ELF*ARM\ aarch64*static*) ;;
  *) echo "PortKit launcher helper is not a static aarch64 ELF: $description" >&2; exit 65 ;;
esac
grep -aFq "$REVISION" "$STAGING/$BINARY.aarch64" || {
  echo "PortKit launcher helper does not contain its source revision" >&2
  exit 65
}
install -m 0755 "$STAGING/$BINARY.aarch64" "$OUT"
printf '%s\n' "$REVISION" > "$REVISION_FILE"
if [ "$BINARY" = portkit-debug-launch ]; then
  "$PYTHON" - "$OUT" <<'PY_SHA'
from pathlib import Path
import hashlib,sys
path=Path(sys.argv[1]);path.with_name(path.name+'.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest()+'\n')
PY_SHA
fi
echo "$description"
