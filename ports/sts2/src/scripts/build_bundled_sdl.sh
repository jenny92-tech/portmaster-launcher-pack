#!/usr/bin/env bash
# Build the port-bundled SDL2 for Longan-class TrimUI firmware.
#
# Why this exists: that firmware's system SDL2 ships no real video driver
# (only dummy/offscreen), and the godot-sdl2 fork renders exclusively through
# SDL-delegated GL. The launcher therefore probes for this library at
# gamedata/libs/ and loads it for stage-2 only, with SDL_VIDEODRIVER=kmsdrm
# (KMSDRM dlopens the device's libdrm/libgbm/libEGL mali shims at runtime).
#
# The artifact is committed (LFS) at src/runtime/sdl2-kmsdrm/ and staged into
# dist/gamedata/libs by dist-port.sh; rebuild only to change the SDL version
# or the driver set.
#
# Constraints encoded here:
#   - debian:bullseye image = glibc 2.31 ceiling (device glibc is < 2.34;
#     a bookworm build fails on-device with GLIBC_2.34 not found).
#   - KMSDRM + ALSA on; wayland/x11/pulse/pipewire/udev off (not on device,
#     and udev off keeps the joystick path on raw /dev/input).
#   - The KMSDRM driver-name string is UPPERCASE — all probes must grep -i.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$SRC_ROOT/runtime/sdl2-kmsdrm"
OUT="$OUT_DIR/libSDL2-2.0.so.0"
SDL_VERSION="${SDL_VERSION:-2.30.11}"
IMAGE="${SDL_BUILD_IMAGE:-debian:bullseye}"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required to build the bundled SDL2." >&2
  exit 69
}

mkdir -p "$OUT_DIR"
docker run --rm --platform linux/arm64 \
  -e SDL_VERSION="$SDL_VERSION" \
  -v "$OUT_DIR:/out" \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    apt-get update -qq
    apt-get install -y -qq build-essential cmake ninja-build wget \
      ca-certificates libdrm-dev libgbm-dev libegl1-mesa-dev \
      libgles2-mesa-dev libasound2-dev pkg-config >/dev/null
    cd /tmp
    wget -q "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VERSION/SDL2-$SDL_VERSION.tar.gz"
    tar xzf "SDL2-$SDL_VERSION.tar.gz"
    cd "SDL2-$SDL_VERSION"
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DSDL_KMSDRM=ON -DSDL_KMSDRM_SHARED=ON \
      -DSDL_WAYLAND=OFF -DSDL_X11=OFF -DSDL_RPI=OFF \
      -DSDL_ALSA=ON -DSDL_PULSEAUDIO=OFF -DSDL_PIPEWIRE=OFF -DSDL_JACK=OFF \
      -DSDL_HIDAPI_LIBUSB=OFF -DSDL_LIBUDEV=OFF \
      -DSDL_SHARED=ON -DSDL_STATIC=OFF | grep -E "SDL_KMSDRM " || true
    cmake --build build -j"$(nproc)" >/dev/null
    LIB="build/libSDL2-2.0.so.0.${SDL_VERSION#2.}"
    LIB="$(ls build/libSDL2-2.0.so.0.*)"
    strip "$LIB"
    grep -aqi kmsdrm "$LIB" || { echo "built SDL2 lacks the KMSDRM driver" >&2; exit 65; }
    MAX_GLIBC=$(readelf --dyn-syms "$LIB" | grep -o "GLIBC_2\.[0-9]*" | sort -uV | tail -1)
    case "$MAX_GLIBC" in
      GLIBC_2.3[4-9]|GLIBC_2.[4-9]*) echo "glibc requirement too new for device: $MAX_GLIBC" >&2; exit 65 ;;
    esac
    install -m 0644 "$LIB" /out/libSDL2-2.0.so.0
    echo "glibc ceiling: $MAX_GLIBC"
  '

description=$(file "$OUT")
case "$description" in
  *ELF*ARM\ aarch64*) ;;
  *) echo "bundled SDL2 is not an aarch64 ELF: $description" >&2; exit 65 ;;
esac
grep -aqi kmsdrm "$OUT" || {
  echo "bundled SDL2 lacks the KMSDRM driver" >&2
  exit 65
}
printf '%s\n' "$SDL_VERSION" > "$OUT_DIR/VERSION"
echo "$description"
