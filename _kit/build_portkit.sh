#!/usr/bin/env bash
# Build the portable static aarch64 PortKit used by selected game launchers.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${PORTKIT_BUILD_IMAGE:-rust:1.88-alpine}"
OUT="$ROOT/_kit/runtime/portkit.aarch64"
REVISION_FILE="$ROOT/_kit/portkit-revision.txt"
STAGING="$ROOT/.tmp/portkit-build"
REVISION="$(python3 "$ROOT/_kit/portkit_revision.py" "$ROOT")"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required to build the portable PortKit CLI." >&2
  exit 69
}

mkdir -p "$STAGING" "$(dirname "$OUT")"
docker run --rm --platform linux/arm64 \
  -e PORTKIT_SOURCE_REVISION="$REVISION" \
  -v "$ROOT:/work" \
  -w /work \
  "$IMAGE" \
  sh -c '
    set -euo pipefail
    apk add --no-cache build-base perl >/dev/null
    CARGO_TARGET_DIR=/tmp/portkit-target \
      cargo build --locked --release -p portkit-cli --bin portkit
    install -m 0755 /tmp/portkit-target/release/portkit /work/.tmp/portkit-build/portkit.aarch64
  '

install -m 0755 "$STAGING/portkit.aarch64" "$OUT"
printf '%s\n' "$REVISION" > "$REVISION_FILE"

description=$(file "$OUT")
case "$description" in
  *ELF*ARM\ aarch64*static*) ;;
  *) echo "PortKit is not a static aarch64 ELF: $description" >&2; exit 65 ;;
esac
grep -aFq "$REVISION" "$OUT" || {
  echo "PortKit does not contain its source revision" >&2
  exit 65
}
echo "$description"
