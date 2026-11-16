#!/bin/bash
# INPUT: Existing cross-toolchain container, SDL/Vulkan headers and probe source.
# OUTPUT: Release ARM64/glibc helper with its own source identity.
# POS: Offline build only; no dependency/image acquisition or engine rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
container="${GRAPHICS_PROBE_BUILD_CONTAINER:-tender_wright}"
headers="${GRAPHICS_PROBE_VULKAN_HEADERS:-/src/dm/linux/out/toolchain/vulkan-headers}"
cache="$ROOT/.cache/graphics-probe"
build_dir="${GRAPHICS_PROBE_BUILD_DIR:-/out/portkit-graphics-probe}"
revision="$(shasum -a 256 "$ROOT/_kit/graphics_probe.c" | cut -d ' ' -f1)"
mkdir -p "$cache" "$ROOT/_kit/runtime"
docker exec "$container" test -f "$headers/vulkan/vulkan.h"
docker exec "$container" mkdir -p "$build_dir"
docker cp "$ROOT/_kit/graphics_probe.c" "$container:${build_dir}/graphics_probe.c" >/dev/null
docker exec -e TMPDIR="$build_dir" "$container" aarch64-linux-gnu-gcc -std=gnu11 -O2 -DNDEBUG -Wall -Wextra -Werror \
    -I"$headers" -DPROBE_BUILD_REVISION=\""$revision"\" \
    "$build_dir/graphics_probe.c" -ldl -o "$build_dir/graphics-probe"
docker exec "$container" aarch64-linux-gnu-strip "$build_dir/graphics-probe"
docker exec "$container" aarch64-linux-gnu-readelf --version-info "$build_dir/graphics-probe" > "$cache/abi.txt"
docker cp "$container:${build_dir}/graphics-probe" "$cache/graphics-probe.aarch64" >/dev/null
file "$cache/graphics-probe.aarch64" | grep -q 'ELF 64-bit.*ARM aarch64'
grep -aFq "PORTKIT_GRAPHICS_PROBE Release $revision" "$cache/graphics-probe.aarch64"
# The accepted lowest firmware is glibc 2.33. Fail a newer libc dependency
# before installing a helper which would silently disable all presentation.
python3 - "$cache/abi.txt" <<'PY'
from pathlib import Path
import re,sys
versions=[tuple(map(int,v.split('.'))) for v in re.findall(r'GLIBC_([0-9.]+)',Path(sys.argv[1]).read_text())]
if not versions or max(versions)>(2,33):raise SystemExit('graphics probe exceeds glibc 2.33 baseline')
PY
install -m 0755 "$cache/graphics-probe.aarch64" "$ROOT/_kit/runtime/graphics-probe.aarch64"
printf '%s\n' "$revision" > "$ROOT/_kit/graphics-probe-revision.txt"
file "$ROOT/_kit/runtime/graphics-probe.aarch64"
