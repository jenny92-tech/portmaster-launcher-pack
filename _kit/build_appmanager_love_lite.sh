#!/usr/bin/env bash
# Build the aarch64 LOVE-lite runtime used only by Port App Manager.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${PAM_LOVE_LITE_BUILD_IMAGE:-rust:1.88-bullseye}"
OUT="$ROOT/ports/appmanager/portable/runtime/love.aarch64"
REVISION_FILE="$ROOT/ports/appmanager/love-lite-revision.txt"
STAGING="$ROOT/.tmp/love-lite-build"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required to build the aarch64 LOVE-lite runtime." >&2
  exit 69
}

mkdir -p "$STAGING" "$(dirname "$OUT")"
docker run --rm --platform linux/arm64 \
  -v "$ROOT:/work" \
  -w /work \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    apt-get update >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends pkg-config libsdl2-dev >/dev/null
    CARGO_TARGET_DIR=/tmp/love-lite-target cargo build --locked --release -p love-lite --features sdl-backend
    install -m 0755 /tmp/love-lite-target/release/love-lite /work/.tmp/love-lite-build/love.aarch64
  '

install -m 0755 "$STAGING/love.aarch64" "$OUT"
python3 "$ROOT/_kit/love_lite_revision.py" "$ROOT" > "$REVISION_FILE"

description=$(file "$OUT")
case "$description" in
  *ELF*ARM\ aarch64*) ;;
  *) echo "LOVE-lite runtime is not an aarch64 ELF: $description" >&2; exit 65 ;;
esac
strings "$OUT" | grep -Fq 'liblove-11.5.so' && {
  echo "LOVE-lite unexpectedly references PortMaster's LÖVE runtime" >&2
  exit 65
}
echo "$description"
