#!/bin/bash
# INPUT: Shared environment plan and native probe installed beside this adapter.
# OUTPUT: Application requirements checked before enabling the NS renderer.
# POS: The shared helper owns surface checks; independentBlend is an NVN requirement.
set -eu
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
output="$("${PORTKIT_LAUNCHER_BIN_OVERRIDE:-$ROOT/bin/portkit-launcher}" session --root "$ROOT" --graphics-probe)"
printf '%s\n' "$output"
if ! printf '%s\n' "$output" | grep -qx PORTKIT_INDEPENDENT_BLEND=1; then
    printf 'Soul Knight NS requires Vulkan independentBlend.\n' >&2
    exit 1
fi
printf 'SOULKNIGHT_VULKAN=1\n'
