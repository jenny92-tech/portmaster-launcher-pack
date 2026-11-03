#!/usr/bin/env bash
# INPUT:  Docker、libdrm/x264/FFmpeg 源码与 Alpine 构建工具链
# OUTPUT: _kit/runtime/ffmpeg.aarch64 静态录屏二进制
# POS:    构建仅含 DRM 抓帧、JPEG 与离线 MP4 编码能力的掌机 FFmpeg
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech
#
# Build the minimal static aarch64 ffmpeg used by the screen recorder
# (kmsgrab 5 fps frame capture + offline MP4 assembly).
#
# The device has no ffmpeg, so the recorder needs one self-contained binary.
# Only what the recorder needs is compiled in:
#   - indev kmsgrab   (DRM plane capture)
#   - wrapped_avframe decoder + hwdownload (KMS frame export to CPU)
#   - mjpeg encoder   (frame capture to .jpg, zero video-encode load in-game)
#   - libx264         (offline assembly of the frame sequence into .mp4)
#   - image2/mp4 muxers/demuxers, hwdownload/format/fps filters
# Static musl build -> one ~few-MB ELF that runs on any aarch64 Linux CFW.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FFMPEG_RECORDER_BUILD_IMAGE:-alpine:3.21}"
OUT="$ROOT/_kit/runtime/ffmpeg.aarch64"
STAGING="$ROOT/.tmp/ffmpeg-recorder-build"
X264_URL="https://code.videolan.org/videolan/x264/-/archive/master/x264-master.tar.gz"
FFMPEG_URL="${FFMPEG_RECORDER_URL:-https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz}"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required to build the recorder ffmpeg." >&2
  exit 69
}

mkdir -p "$STAGING" "$(dirname "$OUT")"
docker run --rm --platform linux/arm64 \
  -e X264_URL="$X264_URL" -e FFMPEG_URL="$FFMPEG_URL" \
  -v "$ROOT:/work" \
  -w /work \
  "$IMAGE" \
  sh -c '
    set -euxo pipefail
    apk add --no-cache build-base linux-headers zlib-dev bzip2-dev xz-dev \
      yasm nasm curl bash meson ninja python3 pkgconf >/dev/null
    cd /tmp
    # Static libdrm: kmsgrab needs it, but alpine ships only shared .so files.
    curl -fsSL --retry 3 -o libdrm.tar.xz https://dri.freedesktop.org/libdrm/libdrm-2.4.123.tar.xz
    tar xJf libdrm.tar.xz
    cd libdrm-2.4.123
    meson setup build -Ddefault_library=static \
      -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled \
      -Dvmwgfx=disabled -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled \
      -Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled \
      -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled \
      -Dtests=false -Dudev=false -Dinstall-test-programs=false \
      -Dprefix=/usr
    ninja -C build && ninja -C build install
    cd /tmp
    curl -fsSL --retry 3 -o x264.tar.gz "$X264_URL"
    tar xzf x264.tar.gz
    # NB: double quotes INSIDE this outer single-quoted string stay literal;
    # single quotes would terminate the outer sh -c string. Glob then picks
    # the single extracted directory regardless of archive naming.
    x264_dir="$(ls -d x264-* 2>/dev/null | head -1 || true)"
    [ -n "$x264_dir" ] && [ -f "$x264_dir/configure" ] || {
      echo "x264 source missing (dir=$x264_dir)"; ls -la; exit 1; }
    cd "$x264_dir"
    ./configure --enable-static --disable-shared --disable-opencl --disable-cli
    make -j"$(nproc)"
    make install
    cd /tmp
    curl -fsSL --retry 3 -o ffmpeg.tar.xz "$FFMPEG_URL"
    tar xJf ffmpeg.tar.xz
    ffmpeg_dir="$(ls -d ffmpeg-* 2>/dev/null | head -1 || true)"
    [ -n "$ffmpeg_dir" ] && [ -f "$ffmpeg_dir/configure" ] || {
      echo "ffmpeg source missing (dir=$ffmpeg_dir)"; ls -la; exit 1; }
    cd "$ffmpeg_dir"
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig ./configure \
      --disable-everything --enable-static --disable-shared \
      --enable-gpl --enable-libx264 --enable-avcodec --enable-avformat \
      --enable-avfilter --enable-avutil --enable-swscale --enable-pthreads \
      --enable-indev=kmsgrab \
      --enable-decoder=mjpeg --enable-decoder=wrapped_avframe \
      --enable-encoder=mjpeg --enable-encoder=libx264 --enable-encoder=rawvideo \
      --enable-muxer=image2 --enable-muxer=mp4 --enable-muxer=rawvideo \
      --enable-demuxer=image2 \
      --enable-parser=mjpeg \
      --enable-filter=hwdownload --enable-filter=format --enable-filter=fps \
      --enable-protocol=file \
      --extra-cflags="-static" --extra-ldflags="-static" \
      --disable-debug --disable-doc --disable-ffplay --disable-ffprobe
    make -j"$(nproc)"
    install -m 0755 ffmpeg /work/.tmp/ffmpeg-recorder-build/ffmpeg.aarch64
    # Feature sanity INSIDE the container: the host cannot exec a Linux ELF.
    ./ffmpeg -hide_banner -devices | grep -q kmsgrab || {
      echo "recorder ffmpeg missing kmsgrab indev"; exit 1; }
    ./ffmpeg -hide_banner -encoders | grep -q libx264 || {
      echo "recorder ffmpeg missing libx264 encoder"; exit 1; }
    ./ffmpeg -hide_banner -encoders | grep -q " mjpeg " || {
      echo "recorder ffmpeg missing mjpeg encoder"; exit 1; }
    ./ffmpeg -hide_banner -decoders | grep -q wrapped_avframe || {
      echo "recorder ffmpeg missing wrapped_avframe decoder"; exit 1; }
  '

install -m 0755 "$STAGING/ffmpeg.aarch64" "$OUT"
rm -rf "$STAGING"

# Host-side checks only: file identity + feature strings (a Linux ELF cannot
# be executed on the build host; feature checks ran inside the container).
description=$(file "$OUT")
case "$description" in
  *ELF*ARM\ aarch64*static*|*ELF*ARM\ aarch64*)
    ;;
  *) echo "recorder ffmpeg is not an aarch64 ELF: $description" >&2; exit 65 ;;
esac
grep -aq kmsgrab "$OUT" || { echo "recorder ffmpeg missing kmsgrab indev" >&2; exit 65; }
grep -aq libx264 "$OUT" || { echo "recorder ffmpeg missing libx264 encoder" >&2; exit 65; }
grep -aq wrapped_avframe "$OUT" || { echo "recorder ffmpeg missing wrapped_avframe decoder" >&2; exit 65; }

echo "$description"
echo ">>> recorder ffmpeg -> $OUT ($(du -h "$OUT" | cut -f1))"
