#!/usr/bin/env bash
# Container-only half of build_appmanager_love_lite.sh.

set -euo pipefail

apt-get update >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  pkg-config libsdl2-dev >/dev/null
FREETYPE2_NO_PKG_CONFIG=1 CARGO_TARGET_DIR=/tmp/love-lite-target \
  cargo build --locked --release -p love-lite --features sdl-backend
install -m 0755 \
  /tmp/love-lite-target/release/love-lite \
  /work/.tmp/love-lite-build/love.aarch64
