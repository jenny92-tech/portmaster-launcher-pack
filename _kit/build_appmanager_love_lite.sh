#!/usr/bin/env bash
# Build the aarch64 LOVE-lite runtime used only by Port App Manager.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${PAM_LOVE_LITE_BUILD_IMAGE:-rust:1.88-bullseye}"
OUT="$ROOT/ports/appmanager/portable/runtime/love.aarch64"
REVISION_FILE="$ROOT/ports/appmanager/love-lite-revision.txt"
STAGING="$ROOT/.tmp/love-lite-build"
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' || {
  echo "Python 3.11 or newer is required to compute the Cargo source revision." >&2
  exit 69
}
REVISION="$(python3 "$ROOT/_kit/love_lite_revision.py" "$ROOT")"
CONTAINER_NAME="pam-love-lite-build-${REVISION:0:12}"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required to build the aarch64 LOVE-lite runtime." >&2
  exit 69
}

mkdir -p "$STAGING" "$(dirname "$OUT")"
docker run --rm --name "$CONTAINER_NAME" --platform linux/arm64 \
  -e LOVE_LITE_SOURCE_REVISION="$REVISION" \
  -v "$ROOT:/work" \
  -w /work \
  "$IMAGE" \
  /work/_kit/build_appmanager_love_lite_in_container.sh

install -m 0755 "$STAGING/love.aarch64" "$OUT"
printf '%s\n' "$REVISION" > "$REVISION_FILE"

description=$(file "$OUT")
case "$description" in
  *ELF*ARM\ aarch64*) ;;
  *) echo "LOVE-lite runtime is not an aarch64 ELF: $description" >&2; exit 65 ;;
esac
grep -aFq 'liblove-11.5.so' "$OUT" && {
  echo "LOVE-lite unexpectedly references PortMaster's LÖVE runtime" >&2
  exit 65
}
grep -aFq 'libfreetype.so' "$OUT" && {
  echo "LOVE-lite unexpectedly references the device FreeType runtime" >&2
  exit 65
}
grep -aFq "$REVISION" "$OUT" || {
  echo "LOVE-lite runtime does not contain its source revision" >&2
  exit 65
}
echo "$description"
